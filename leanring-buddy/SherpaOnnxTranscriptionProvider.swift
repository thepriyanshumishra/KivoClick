//
//  SherpaOnnxTranscriptionProvider.swift
//  leanring-buddy
//
//  Local offline transcription provider backed by WhisperKit (whisper-small multilingual).
//  Supports 99 languages including English and Hindi with no API calls required
//  after the initial one-time model download.
//
//  Audio pipeline:
//    AVAudioPCMBuffer → Float32 conversion → VAD silence detection
//    → chunk transcription via WhisperKit → transcript accumulation → UI update
//

import AVFoundation
import Foundation
import WhisperKit

// MARK: - SherpaOnnxTranscriptionProvider

/// Offline transcription provider using WhisperKit (Whisper-Small multilingual).
/// Drop-in replacement for WhisperTranscriptionProvider — conforms to
/// BuddyTranscriptionProvider and plugs into the existing dictation pipeline.
final class SherpaOnnxTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Whisper Local (Offline)"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        SherpaOnnxModelManager.shared.isModelReady
    }

    var unavailableExplanation: String? {
        if SherpaOnnxModelManager.shared.downloadProgress != nil {
            return "Model is downloading…"
        }
        return "AI model not yet downloaded. Open Kivo Click to download."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured,
              let whisperKit = SherpaOnnxModelManager.shared.whisperKit else {
            throw SherpaOnnxTranscriptionError(
                message: "WhisperKit model not ready. Please wait for download to complete."
            )
        }

        return SherpaOnnxTranscriptionSession(
            whisperKit: whisperKit,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

// MARK: - SherpaOnnxTranscriptionSession

/// One push-to-talk recording session. Buffers audio as Float32 samples,
/// runs VAD-based chunked transcription during recording, and delivers a
/// final concatenated transcript when the user releases the push-to-talk button.
private final class SherpaOnnxTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// How long to wait after the last audio buffer before the session is considered timed out.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 6.0

    // MARK: - VAD Configuration

    /// RMS energy below this threshold is considered silence.
    private static let vadSilenceEnergyThreshold: Float = 0.01

    /// Consecutive silent buffers needed to trigger a chunk transcription.
    /// At ~100ms per buffer, 8 buffers ≈ 800ms of silence before transcribing.
    private static let vadSilentBufferCountTrigger: Int = 8

    /// Maximum audio seconds to buffer before forcing transcription, regardless of silence.
    /// Prevents very large chunks on continuous speech.
    private static let vadMaxChunkDurationSeconds: Double = 6.0

    /// Minimum seconds of audio required before attempting transcription.
    /// Prevents sending near-empty buffers to WhisperKit.
    private static let minimumChunkDurationSeconds: Double = 0.5

    // MARK: - Audio Configuration

    /// WhisperKit requires 16kHz mono Float32 audio.
    private static let targetSampleRate: Double = 16_000

    // MARK: - State

    private let stateQueue = DispatchQueue(label: "com.kivoclicks.whisperkit.session")

    /// Audio samples buffered for the current VAD chunk (Float32, 16kHz mono).
    private var currentChunkFloat32Samples: [Float] = []

    /// Full accumulated transcript across all chunks in this session.
    private var accumulatedTranscriptText = ""

    private var consecutiveSilentBufferCount = 0
    private var currentChunkStartTime = Date()

    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var activeTranscriptionTask: Task<Void, Never>?

    private let whisperKit: WhisperKit
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    /// Reusable AVAudioConverter to resample incoming audio to 16kHz mono Float32.
    private var audioResampler: AVAudioConverter?
    private var resamplingOutputFormat: AVAudioFormat?

    // MARK: - Init

    init(
        whisperKit: WhisperKit,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.whisperKit = whisperKit
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    // MARK: - BuddyStreamingTranscriptionSession

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        // Convert incoming buffer to Float32 samples at 16kHz mono
        guard let float32Samples = resampleToWhisperFormat(audioBuffer) else { return }
        guard !float32Samples.isEmpty else { return }

        let rmsEnergy = computeRMSEnergy(of: float32Samples)

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }

            self.currentChunkFloat32Samples.append(contentsOf: float32Samples)

            // VAD: track consecutive silent buffers
            if rmsEnergy < Self.vadSilenceEnergyThreshold {
                self.consecutiveSilentBufferCount += 1
            } else {
                self.consecutiveSilentBufferCount = 0
            }

            let chunkDurationSeconds = Double(self.currentChunkFloat32Samples.count) / Self.targetSampleRate
            let silenceTriggered = self.consecutiveSilentBufferCount >= Self.vadSilentBufferCountTrigger
            let maxDurationTriggered = chunkDurationSeconds >= Self.vadMaxChunkDurationSeconds
            let hasEnoughAudioToTranscribe = chunkDurationSeconds >= Self.minimumChunkDurationSeconds

            if hasEnoughAudioToTranscribe && (silenceTriggered || maxDurationTriggered) {
                let chunkSamplesToTranscribe = self.currentChunkFloat32Samples
                self.currentChunkFloat32Samples = []
                self.consecutiveSilentBufferCount = 0
                self.currentChunkStartTime = Date()

                self.activeTranscriptionTask = Task { [weak self] in
                    await self?.transcribeChunkAndAppend(chunkSamplesToTranscribe)
                }
            }
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            // Cancel in-flight VAD chunk task to avoid racing with final transcript
            self.activeTranscriptionTask?.cancel()

            let remainingSamples = self.currentChunkFloat32Samples
            self.currentChunkFloat32Samples = []

            self.activeTranscriptionTask = Task { [weak self] in
                guard let self else { return }

                // Transcribe any remaining buffered audio
                if !remainingSamples.isEmpty {
                    await self.transcribeChunkAndAppend(remainingSamples)
                }

                let finalText = self.stateQueue.sync { self.accumulatedTranscriptText }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.deliverFinalTranscriptIfNeeded(finalText)
            }
        }
    }

    func cancel() {
        stateQueue.sync {
            isCancelled = true
            currentChunkFloat32Samples.removeAll(keepingCapacity: false)
        }
        activeTranscriptionTask?.cancel()
    }

    // MARK: - Chunk Transcription

    /// Transcribes one Float32 audio chunk via WhisperKit and appends the
    /// result to the accumulated transcript, firing onTranscriptUpdate immediately.
    private func transcribeChunkAndAppend(_ float32Samples: [Float]) async {
        guard !Task.isCancelled else { return }
        guard !stateQueue.sync(execute: { isCancelled }) else { return }
        guard !float32Samples.isEmpty else { return }

        do {
            // DecodingOptions: multilingual mode (language = nil means auto-detect),
            // greedy decoding for speed, no timestamps needed for plain transcript.
            let decodingOptions = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: nil,          // nil = auto-detect language from audio
                temperature: 0.0,       // greedy (deterministic, fastest)
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )

            let transcriptionResults = try await whisperKit.transcribe(
                audioArray: float32Samples,
                decodeOptions: decodingOptions
            )

            let chunkText = transcriptionResults
                .compactMap { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !chunkText.isEmpty else { return }
            guard !Task.isCancelled, !stateQueue.sync(execute: { isCancelled }) else { return }

            stateQueue.async {
                if !self.accumulatedTranscriptText.isEmpty {
                    self.accumulatedTranscriptText += " "
                }
                self.accumulatedTranscriptText += chunkText

                let currentFullTranscript = self.accumulatedTranscriptText
                DispatchQueue.main.async {
                    self.onTranscriptUpdate(currentFullTranscript)
                }
            }

            print("🎙️ WhisperKit: Chunk → \"\(chunkText)\"")
        } catch {
            // Non-fatal: a single chunk failure doesn't end the session
            print("🎙️ WhisperKit: Chunk transcription error: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio Resampling

    /// Converts an AVAudioPCMBuffer from any sample rate/format to
    /// 16kHz mono Float32 samples required by WhisperKit.
    private func resampleToWhisperFormat(_ inputBuffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = inputBuffer.format

        // Build (or reuse) the 16kHz mono Float32 output format
        if resamplingOutputFormat == nil {
            resamplingOutputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetSampleRate,
                channels: 1,
                interleaved: false
            )
        }

        guard let outputFormat = resamplingOutputFormat else { return nil }

        // Build (or reuse) the converter if the input format changed
        if audioResampler == nil || audioResampler?.inputFormat != inputFormat {
            audioResampler = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        guard let converter = audioResampler else { return nil }

        // Calculate output frame capacity proportional to the sample rate ratio
        let sampleRateRatio = Self.targetSampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            Double(inputBuffer.frameLength) * sampleRateRatio + 1
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return nil }

        var conversionError: NSError?
        var inputBufferConsumed = false

        // The conversion input block is called once per convert() call
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputBufferConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputBufferConsumed = true
            return inputBuffer
        }

        guard conversionStatus != .error, conversionError == nil else {
            print("🎙️ WhisperKit: Audio resampling error: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData, count: frameCount))
    }

    // MARK: - RMS Energy (VAD)

    /// Computes root-mean-square energy of Float32 samples normalized 0–1.
    /// Values below vadSilenceEnergyThreshold are treated as silence by VAD.
    private func computeRMSEnergy(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    // MARK: - Final Transcript Delivery

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        DispatchQueue.main.async {
            self.onFinalTranscriptReady(transcriptText)
        }
    }

    deinit {
        cancel()
    }
}

// MARK: - Error

struct SherpaOnnxTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
