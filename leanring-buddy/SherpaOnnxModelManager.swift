//
//  SherpaOnnxModelManager.swift
//  leanring-buddy
//
//  Manages WhisperKit model download and lifecycle.
//  Named SherpaOnnx* to avoid Xcode target membership changes —
//  the underlying engine was swapped from sherpa-onnx to WhisperKit.
//
//  WhisperKit automatically caches the model to:
//    ~/Library/Caches/huggingface/hub/models--argmaxinc--whisperkit-coreml/
//  After the first download, subsequent launches load from cache instantly.
//

import Combine
import Foundation
import WhisperKit

/// Manages the one-time WhisperKit model download and shared instance lifecycle.
/// Observable so CompanionPanelView can show live download progress.
final class SherpaOnnxModelManager: ObservableObject {

    // MARK: - Singleton

    static let shared = SherpaOnnxModelManager()

    // MARK: - Published State

    /// Progress 0.0–1.0 while downloading. Nil means not currently downloading.
    @Published var downloadProgress: Double? = nil

    /// True once the WhisperKit instance is loaded and ready to transcribe.
    @Published var isModelReady: Bool = false

    /// Non-nil if the download or initialization failed.
    @Published var downloadError: String? = nil

    // MARK: - Shared WhisperKit Instance

    /// The loaded WhisperKit recognizer. Nil until download + initialization completes.
    /// Used directly by SherpaOnnxTranscriptionSession to transcribe audio chunks.
    private(set) var whisperKit: WhisperKit?

    // MARK: - Model Configuration

    /// The Whisper model variant to download. whisper-small gives the best
    /// balance of accuracy (99 languages including Hindi) and speed for
    /// short push-to-talk audio clips.
    private static let whisperModelVariant = "openai_whisper-small"

    // MARK: - Init

    private init() {
        // On every launch, silently attempt to load from HuggingFace local cache.
        // This completes instantly if the model was previously downloaded —
        // WhisperKit checks the local cache before making any network request.
        Task { @MainActor [weak self] in
            await self?.silentlyLoadFromCacheIfAvailable()
        }
    }

    // MARK: - Public API

    /// Downloads the WhisperKit model if not cached, then initializes the recognizer.
    /// Safe to call multiple times — returns immediately if already ready or in progress.
    @MainActor
    func downloadModelIfNeeded() async {
        guard !isModelReady, downloadProgress == nil else { return }

        downloadError = nil
        downloadProgress = 0.0

        do {
            print("📦 WhisperKit: Starting model download/load for \(Self.whisperModelVariant)")

            // WhisperKit.download fetches the model from HuggingFace and caches it.
            // If the model is already cached locally, this returns immediately.
            let cachedModelFolderURL = try await WhisperKit.download(
                variant: Self.whisperModelVariant,
                progressCallback: { [weak self] downloadProgress in
                    Task { @MainActor [weak self] in
                        // Only show progress if we haven't finished yet —
                        // cached downloads complete instantly and skip this
                        self?.downloadProgress = downloadProgress.fractionCompleted
                    }
                }
            )

            print("📦 WhisperKit: Model folder: \(cachedModelFolderURL.path)")
            downloadProgress = nil

            // Initialize the WhisperKit instance from the cached local model folder.
            // cachedModelFolderURL is a URL — WhisperKit(modelFolder:) takes a String path.
            let loadedWhisperKit = try await WhisperKit(modelFolder: cachedModelFolderURL.path)
            self.whisperKit = loadedWhisperKit
            self.isModelReady = true

            print("📦 WhisperKit: ✅ Model ready for transcription")
        } catch {
            downloadProgress = nil
            downloadError = "Download failed: \(error.localizedDescription)"
            print("📦 WhisperKit: ❌ Failed: \(error)")
        }
    }

    // MARK: - Private Cache Loading

    /// Silently attempts to load WhisperKit from the local HuggingFace cache on app launch.
    /// If the model was downloaded in a previous session, this makes the banner disappear
    /// immediately without requiring the user to tap "Download" again.
    @MainActor
    private func silentlyLoadFromCacheIfAvailable() async {
        do {
            // WhisperKit.download with no progress callback — returns instantly from cache
            // if model files are present, or throws if not cached.
            let cachedModelFolderURL = try await WhisperKit.download(
                variant: Self.whisperModelVariant,
                progressCallback: nil
            )

            let loadedWhisperKit = try await WhisperKit(modelFolder: cachedModelFolderURL.path)
            self.whisperKit = loadedWhisperKit
            self.isModelReady = true

            print("📦 WhisperKit: ✅ Loaded from cache on startup")
        } catch {
            // Model not cached yet — banner will prompt the user to download
            print("📦 WhisperKit: Not cached, download required")
        }
    }
}
