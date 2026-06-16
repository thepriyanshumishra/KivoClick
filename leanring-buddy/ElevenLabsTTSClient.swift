//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Routes TTS through the Cloudflare Worker proxy.
//  Voices Hannah/Daniel → Orpheus (Groq), Aoede/Puck → Gemini TTS.
//
//  GAP FIX:
//  The original code ran the entire URLSession fetch on @MainActor and
//  never called prepareToPlay() — this caused 100-300ms gaps at the start
//  of each audio segment because AVAudioPlayer had to initialise its audio
//  hardware connection inline with the first play() call.
//
//  This version:
//    1. Fetches audio data on a background Task (off main actor).
//    2. Calls prepareToPlay() while still on the background thread so the
//       audio hardware session is warm before we call play().
//    3. Returns to @MainActor only to set the player and call play() — this
//       is the minimum work needed on main and eliminates the gap.
//    4. Removes the rate=0.88 slowdown (enableRate=true causes the DSP
//       time-stretcher to initialise lazily on first play, adding jitter).
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

    // MARK: - speakText

    /// Fetches PCM audio from the worker proxy and plays it immediately with
    /// minimal gap. The heavy work (network fetch + WAV wrapping +
    /// prepareToPlay) happens off the main actor so UI stays responsive.
    func speakText(_ text: String, voice: String) async throws {
        stopPlayback()

        let cleanedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedText.isEmpty else { return }

        do {
            // ── Step 1: Build the request on MainActor (fast — no I/O) ────────
            guard let url = URL(string: proxyURL) else {
                throw NSError(
                    domain: "ElevenLabsTTSClient", code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid proxy URL"]
                )
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let jsonPayload = ["text": cleanedText, "voice": voice]
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonPayload)

            print("🔊 Requesting TTS (\(voice)) from proxy. Text length: \(cleanedText.count) chars")

            // ── Step 2: Fetch + wrap + prepare — all OFF main actor ───────────
            // Suspension point here releases @MainActor so SwiftUI/AppKit
            // can continue rendering cursor animations while we wait for
            // the network response. This is the main fix for the gaps.
            let player: AVAudioPlayer = try await Task.detached(priority: .userInitiated) {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                    print("⚠️ TTS proxy error (status \(status)): \(errorMsg)")
                    throw NSError(
                        domain: "ElevenLabsTTSClient", code: status,
                        userInfo: [NSLocalizedDescriptionKey: errorMsg]
                    )
                }

                // Both Gemini and Orpheus routes return raw PCM16 mono.
                // Gemini TTS: 24 kHz — Orpheus (Groq): 24 kHz.
                let wavData = BuddyWAVFileBuilder.buildWAVData(
                    fromPCM16MonoAudio: data,
                    sampleRate: 24000
                )

                let audioPlayer = try AVAudioPlayer(data: wavData)
                // Pre-warm the audio hardware connection NOW, before we
                // return to the main actor. This eliminates the startup gap
                // that occurred when play() had to do this work inline.
                audioPlayer.prepareToPlay()
                return audioPlayer

            }.value

            // ── Step 3: Hand off to main actor — set delegate and press play ──
            // At this point prepareToPlay() is done; play() is near-instant.
            player.delegate = self
            audioPlayer = player
            isCurrentlySpeaking = true
            player.play()
            print("🔊 Playing synthesized audio via AVAudioPlayer (duration: \(String(format: "%.2f", player.duration))s)")

        } catch {
            print("⚠️ TTS playback failed: \(error.localizedDescription). Attempting premium fallback...")
            try await playFallbackErrorAudio(voice: voice, error: error)
        }
    }

    // MARK: - Fallback Error Audio

    /// Plays a locally bundled error audio clip when TTS fetch fails.
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

    /// Whether audio is currently playing back.
    var isPlaying: Bool {
        isCurrentlySpeaking && (audioPlayer?.isPlaying ?? false)
    }

    /// Elapsed playback time of the current audio clip.
    var currentTime: TimeInterval {
        audioPlayer?.currentTime ?? 0
    }

    /// Total duration of the current audio clip.
    var duration: TimeInterval {
        audioPlayer?.duration ?? 0
    }

    /// Current playback rate (1.0 = normal speed).
    var rate: Float {
        audioPlayer?.rate ?? 1.0
    }

    /// Stops speech immediately and resets state.
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
