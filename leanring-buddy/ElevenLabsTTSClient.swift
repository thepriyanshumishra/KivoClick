//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Redirects TTS calls to local Kokoro TTS via SherpaOnnx.
//

import AVFoundation
import Foundation
import SherpaOnnx

@MainActor
final class ElevenLabsTTSClient: NSObject, AVAudioPlayerDelegate {
    private let proxyURL: String
    private var audioPlayer: AVAudioPlayer?
    private var isCurrentlySpeaking = false
    private var ttsInstance: SherpaOnnxOfflineTtsWrapper?
    var onPlaybackStateChanged: (@Sendable @MainActor (Bool) -> Void)?

    init(proxyURL: String) {
        self.proxyURL = proxyURL
        super.init()
    }

    // MARK: - getOrInitTTS

    /// Lazily initializes and returns the SherpaOnnx OfflineTts engine using local model files.
    private func getOrInitTTS() throws -> SherpaOnnxOfflineTtsWrapper {
        if let tts = ttsInstance {
            return tts
        }

        let manager = KokoroTTSModelManager.shared
        guard manager.isModelReady else {
            throw NSError(
                domain: "ElevenLabsTTSClient",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Local voice model not ready. Please download it from settings first."]
            )
        }

        // Configure Kokoro model paths
        let kokoroConfig = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: manager.modelURL.path,
            voices: manager.voicesURL.path,
            tokens: manager.tokensURL.path,
            dataDir: manager.espeakDataURL.path,
            lengthScale: 1.0
        )

        let modelConfig = sherpaOnnxOfflineTtsModelConfig(
            kokoro: kokoroConfig,
            numThreads: 4,
            debug: 0,
            provider: "cpu"
        )

        var ttsConfig = sherpaOnnxOfflineTtsConfig(
            model: modelConfig,
            ruleFsts: ""
        )

        let tts = withUnsafePointer(to: &ttsConfig) { configPtr in
            return SherpaOnnxOfflineTtsWrapper(config: configPtr)
        }
        
        self.ttsInstance = tts
        print("🔊 KokoroTTSClient: Initialized SherpaOnnx OfflineTtsWrapper successfully.")
        return tts
    }

    // MARK: - speakText

    /// Synthesizes speech locally using Kokoro TTS and plays it immediately with minimal gap.
    func speakText(_ text: String, voice: String) async throws {
        stopPlayback()

        let cleanedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedText.isEmpty else { return }

        do {
            // Get/Init the local TTS engine
            let tts = try getOrInitTTS()

            // Map selected voice name to Kokoro speaker ID (sid)
            let voiceLower = voice.lowercased()
            let sid: Int
            if voiceLower == "aoede" {
                sid = 7 // af_aoede
            } else if voiceLower == "puck" {
                sid = 10 // pm_alex
            } else if voiceLower == "hannah" {
                sid = 1 // af_bella
            } else if voiceLower == "daniel" {
                sid = 11 // pm_santa
            } else {
                sid = 7 // Default fallback to af_aoede
            }

            print("🔊 Local Kokoro TTS: Synthesizing (\(voice) -> sid: \(sid)). Text: \"\(cleanedText)\"")

            // Perform synthesis and WAV wrapping off the main actor
            let player: AVAudioPlayer = try await Task.detached(priority: .userInitiated) {
                // Generate audio samples (Float array) using speed setting from UserDefaults
                let speedVal = UserDefaults.standard.double(forKey: "kivoVoiceSpeed")
                let finalSpeed = speedVal > 0.1 ? Float(speedVal) : 1.0
                let audio = tts.generate(text: cleanedText, sid: sid, speed: finalSpeed)
                let samples = audio.samples
                let sampleRate = audio.sampleRate

                // Convert Float samples to Int16 PCM data
                var pcmData = Data(capacity: samples.count * 2)
                for sample in samples {
                    let clamped = max(-1.0, min(1.0, sample))
                    let intVal = Int16(clamped * 32767.0)
                    withUnsafeBytes(of: intVal.littleEndian) { pcmData.append(contentsOf: $0) }
                }

                // Wrap PCM data in WAV header
                let wavData = BuddyWAVFileBuilder.buildWAVData(
                    fromPCM16MonoAudio: pcmData,
                    sampleRate: Int(sampleRate)
                )

                let audioPlayer = try AVAudioPlayer(data: wavData)
                audioPlayer.prepareToPlay()
                return audioPlayer
            }.value

            // Hand off to main actor for playback
            player.delegate = self
            audioPlayer = player
            isCurrentlySpeaking = true
            player.play()
            onPlaybackStateChanged?(true)
            print("🔊 Local Kokoro TTS: Playing synthesized audio (duration: \(String(format: "%.2f", player.duration))s)")

        } catch {
            print("⚠️ Local Kokoro TTS playback failed: \(error.localizedDescription). Attempting fallback...")
            try await playFallbackErrorAudio(voice: voice, error: error)
        }
    }

    /// Plays a pre-bundled voice sample for preview purposes in settings.
    func playSample(for voice: String) {
        stopPlayback()
        let voiceLower = voice.lowercased()
        let assetName = "general_error_\(voiceLower)"
        guard let assetURL = Bundle.main.url(forResource: assetName, withExtension: "wav") else {
            print("⚠️ Sample audio \(assetName).wav not found")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: assetURL)
            player.delegate = self
            player.prepareToPlay()
            self.audioPlayer = player
            self.isCurrentlySpeaking = true
            player.play()
            onPlaybackStateChanged?(true)
            print("🔊 Local Voice Preview: Playing sample \(assetName).wav")
        } catch {
            print("⚠️ Failed to play voice sample: \(error.localizedDescription)")
        }
    }

    // MARK: - Fallback Error Audio

    /// Plays a locally bundled error audio clip when TTS fails.
    private func playFallbackErrorAudio(voice: String, error: Error) async throws {
        let voiceLower = voice.lowercased()
        let voiceSuffix: String
        if voiceLower == "puck"         { voiceSuffix = "puck"   }
        else if voiceLower == "hannah"  { voiceSuffix = "hannah" }
        else if voiceLower == "daniel"  { voiceSuffix = "daniel" }
        else                            { voiceSuffix = "aoede"  }

        let nsError = error as NSError
        let isRateLimit   = nsError.code == 429
            || error.localizedDescription.contains("429")
            || error.localizedDescription.contains("quota")
            || error.localizedDescription.contains("limit")
        let isNetworkError = nsError.code == -1009
            || nsError.domain == NSURLErrorDomain
            || error.localizedDescription.contains("offline")
            || error.localizedDescription.contains("connection")
            || error.localizedDescription.contains("not connected")

        let errorAssetPrefix = isRateLimit ? "limit_exceeded"
                             : isNetworkError ? "network_error"
                             : "general_error"
        let assetName = "\(errorAssetPrefix)_\(voiceSuffix)"

        print("🎯 Loading local error asset: \(assetName).wav")

        if let assetURL = Bundle.main.url(forResource: assetName, withExtension: "wav") {
            do {
                let player = try AVAudioPlayer(contentsOf: assetURL)
                player.delegate = self
                player.prepareToPlay()
                self.audioPlayer = player
                self.isCurrentlySpeaking = true
                player.play()
                print("🔊 Playing local premium error audio: \(assetName).wav")
                return
            } catch {
                print("⚠️ Failed to play local error asset: \(error.localizedDescription)")
            }
        } else {
            print("⚠️ Local error asset \(assetName).wav not found in bundle.")
        }

        throw error
    }

    // MARK: - Playback State

    var isPlaying: Bool {
        isCurrentlySpeaking && (audioPlayer?.isPlaying ?? false)
    }

    var currentTime: TimeInterval {
        audioPlayer?.currentTime ?? 0
    }

    var duration: TimeInterval {
        audioPlayer?.duration ?? 0
    }

    var rate: Float {
        audioPlayer?.rate ?? 1.0
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isCurrentlySpeaking = false
        onPlaybackStateChanged?(false)
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isCurrentlySpeaking = false
            onPlaybackStateChanged?(false)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        if let error = error {
            print("⚠️ AVAudioPlayer decode error: \(error.localizedDescription)")
        }
        Task { @MainActor in
            isCurrentlySpeaking = false
            onPlaybackStateChanged?(false)
        }
    }
}
