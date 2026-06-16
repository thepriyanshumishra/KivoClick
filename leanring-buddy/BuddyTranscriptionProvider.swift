//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        // Primary: SherpaOnnxTranscriptionProvider (WhisperKit offline, 99 languages)
        // Loaded automatically when the whisper-small model has been downloaded.
        let sherpaOnnxProvider = SherpaOnnxTranscriptionProvider()
        if sherpaOnnxProvider.isConfigured {
            return sherpaOnnxProvider
        }

        // Fallback: WhisperTranscriptionProvider (local whisper.cpp server on :8080,
        // then Groq Whisper API). Used while the WhisperKit model is still downloading
        // or if the download hasn't been started yet.
        print("⚠️ Transcription: WhisperKit model not ready, falling back to Whisper (local/Groq)")
        return WhisperTranscriptionProvider()
    }
}
