//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Rebranded/Redirected to use Google Gemini TTS via Worker Proxy
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient: NSObject, AVAudioPlayerDelegate {
    private let proxyURL: String
    private var audioPlayer: AVAudioPlayer?
    private var isCurrentlySpeaking = false

    init(proxyURL: String) {
        self.proxyURL = proxyURL
        super.init()
    }

    /// Speaks the given text by fetching audio from Gemini TTS via Cloudflare Worker proxy using the selected voice.
    /// If an error or rate limit occurs, it falls back to playing pre-saved premium error audio files.
    func speakText(_ text: String, voice: String) async throws {
        stopPlayback()
        
        let cleanedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            
        guard !cleanedText.isEmpty else { return }
        
        do {
            // Fetch raw PCM from proxy
            guard let url = URL(string: proxyURL) else {
                throw NSError(domain: "ElevenLabsTTSClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid proxy URL"])
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let jsonPayload = ["text": cleanedText, "voice": voice]
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonPayload)
            
            print("🔊 Requesting Gemini/Azure TTS (\(voice)) from proxy for text: \"\(cleanedText)\"")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("⚠️ TTS proxy error (status \(status)): \(errorMsg)")
                throw NSError(domain: "ElevenLabsTTSClient", code: status, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            
            // Wrap PCM16 mono bytes in WAV header
            // Gemini / Azure audio output is 24000 Hz, mono, PCM 16-bit
            let wavData = BuddyWAVFileBuilder.buildWAVData(
                fromPCM16MonoAudio: data,
                sampleRate: 24000
            )
            
            // Initialize and play audio
            let player = try AVAudioPlayer(data: wavData)
            player.delegate = self
            
            // Slow down audio slightly to sound more natural and less rushed
            player.enableRate = true
            player.rate = 0.88
            
            audioPlayer = player
            isCurrentlySpeaking = true
            player.play()
            print("🔊 Playing synthesized audio via AVAudioPlayer (rate: 0.88)")
            
        } catch {
            print("⚠️ TTS playback failed: \(error.localizedDescription). Attempting premium fallback...")
            
            let voiceLower = voice.lowercased()
            let voiceSuffix: String
            if voiceLower == "puck" {
                voiceSuffix = "puck"
            } else if voiceLower == "hannah" {
                voiceSuffix = "hannah"
            } else if voiceLower == "daniel" {
                voiceSuffix = "daniel"
            } else {
                voiceSuffix = "aoede"
            }
            
            // Determine asset name based on error type
            let nsError = error as NSError
            let isRateLimit = nsError.code == 429 || nsError.localizedDescription.contains("429") || nsError.localizedDescription.contains("quota") || nsError.localizedDescription.contains("limit")
            let isNetworkError = nsError.code == -1009 || nsError.domain == NSURLErrorDomain || nsError.localizedDescription.contains("offline") || nsError.localizedDescription.contains("connection") || nsError.localizedDescription.contains("not connected")
            
            let errorAssetPrefix = isRateLimit ? "limit_exceeded" : (isNetworkError ? "network_error" : "general_error")
            let assetName = "\(errorAssetPrefix)_\(voiceSuffix)"
            
            print("🎯 Loading local error asset: \(assetName).wav")
            
            if let assetURL = Bundle.main.url(forResource: assetName, withExtension: "wav") {
                do {
                    let player = try AVAudioPlayer(contentsOf: assetURL)
                    player.delegate = self
                    player.enableRate = true
                    player.rate = 0.88
                    
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
            
            // Rethrow the error if local asset playback fails
            throw error
        }
    }

    /// Whether native audio is currently playing back.
    var isPlaying: Bool {
        isCurrentlySpeaking && (audioPlayer?.isPlaying ?? false)
    }

    /// The current playback time of the audio player.
    var currentTime: TimeInterval {
        audioPlayer?.currentTime ?? 0
    }

    /// The total duration of the audio player.
    var duration: TimeInterval {
        audioPlayer?.duration ?? 0
    }

    /// The current playback rate of the audio player.
    var rate: Float {
        audioPlayer?.rate ?? 1.0
    }

    /// Stops speech synthesis immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isCurrentlySpeaking = false
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isCurrentlySpeaking = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        if let error = error {
            print("⚠️ AVAudioPlayer decode error: \(error.localizedDescription)")
        }
        Task { @MainActor in
            isCurrentlySpeaking = false
        }
    }
}
