//
//  WhisperTranscriptionProvider.swift
//  leanring-buddy
//
//  Cross-platform local/fallback Whisper transcription provider.
//

import AVFoundation
import Foundation

struct WhisperTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class WhisperTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Whisper"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        return WhisperTranscriptionSession(
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class WhisperTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8.0

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private static let localWhisperURL = URL(string: "http://localhost:8080/v1/audio/transcriptions")!
    private static let fallbackWorkerURL = URL(string: "http://localhost:8787/transcribe")!
    private static let targetSampleRate = 16_000

    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.whisper.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.timeoutIntervalForRequest = 5 // Fast fail for local offline check
        urlSessionConfiguration.timeoutIntervalForResource = 30
        urlSessionConfiguration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            self?.isCancelled = true
            self?.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let trimmedAudioDataIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if trimmedAudioDataIsEmpty {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        // 1. Try Local Whisper Engine
        do {
            print("🎙️ Whisper STT: Attempting local engine at \(Self.localWhisperURL)")
            let transcriptText = try await requestTranscription(for: wavAudioData, url: Self.localWhisperURL, isLocal: true)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            print("🎙️ Whisper STT: Local engine transcription succeeded!")
            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
            return
        } catch {
            print("🎙️ Whisper STT: ⚠️ Local transcription failed: \(error.localizedDescription). Falling back to Groq Whisper...")
        }

        // 2. Fallback to Groq Whisper via Cloudflare Worker Proxy
        do {
            let transcriptText = try await requestTranscription(for: wavAudioData, url: Self.fallbackWorkerURL, isLocal: false)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            print("🎙️ Whisper STT: Fallback Groq transcription succeeded!")
            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("🎙️ Whisper STT: ❌ Fallback transcription failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    private func requestTranscription(for wavAudioData: Data, url: URL, isLocal: Bool) async throws -> String {
        let multipartBoundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(multipartBoundary)", forHTTPHeaderField: "Content-Type")

        let requestBodyData = makeMultipartRequestBody(
            boundary: multipartBoundary,
            wavAudioData: wavAudioData,
            isLocal: isLocal
        )
        request.httpBody = requestBodyData

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperTranscriptionProviderError(
                message: "Whisper transcription returned an invalid response."
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw WhisperTranscriptionProviderError(
                message: "Whisper transcription failed: \(responseText)"
            )
        }

        if let transcriptionResponse = try? JSONDecoder().decode(
            TranscriptionResponse.self,
            from: responseData
        ) {
            return transcriptionResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let responseText = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !responseText.isEmpty {
            return responseText
        }

        throw WhisperTranscriptionProviderError(
            message: "Whisper transcription returned an empty transcript."
        )
    }

    private func makeMultipartRequestBody(
        boundary: String,
        wavAudioData: Data,
        isLocal: Bool
    ) -> Data {
        var requestBodyData = Data()

        if isLocal {
            requestBodyData.appendMultipartFormField(
                named: "response_format",
                value: "json",
                usingBoundary: boundary
            )
        } else {
            requestBodyData.appendMultipartFormField(
                named: "model",
                value: "whisper-large-v3-turbo",
                usingBoundary: boundary
            )
        }

        requestBodyData.appendMultipartFileField(
            named: "file",
            filename: "voice-input.wav",
            mimeType: "audio/wav",
            fileData: wavAudioData,
            usingBoundary: boundary
        )
        requestBodyData.appendString("--\(boundary)--\r\n")

        return requestBodyData
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8)!)
    }

    mutating func appendMultipartFormField(
        named fieldName: String,
        value: String,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFileField(
        named fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(fileData)
        appendString("\r\n")
    }
}
