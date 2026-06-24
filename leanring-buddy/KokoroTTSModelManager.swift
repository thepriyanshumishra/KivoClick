//
//  KokoroTTSModelManager.swift
//  leanring-buddy
//
//  Manages local Kokoro TTS model download, caching, and extraction.
//

import Combine
import Foundation

/// Manages downloading and caching of the Kokoro ONNX model and its assets locally.
@MainActor
final class KokoroTTSModelManager: ObservableObject {
    
    // MARK: - Singleton
    static let shared = KokoroTTSModelManager()

    // MARK: - Published State
    @Published var downloadProgress: Double? = nil
    @Published var isModelReady: Bool = false
    @Published var downloadError: String? = nil

    private var activeDownloadTask: URLSessionDownloadTask?
    
    // MARK: - Paths
    private var rootDirectoryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kokoro-tts")
    }

    private var modelFolderURL: URL {
        rootDirectoryURL.appendingPathComponent("kokoro-en-v0_19")
    }

    var modelURL: URL { modelFolderURL.appendingPathComponent("model.onnx") }
    var voicesURL: URL { modelFolderURL.appendingPathComponent("voices.bin") }
    var tokensURL: URL { modelFolderURL.appendingPathComponent("tokens.txt") }
    var espeakDataURL: URL { modelFolderURL.appendingPathComponent("espeak-ng-data") }

    // MARK: - Init
    private init() {
        checkIfModelFilesExist()
    }

    // MARK: - Check Status
    func checkIfModelFilesExist() {
        let fm = FileManager.default
        let isReady = fm.fileExists(atPath: modelURL.path) &&
                      fm.fileExists(atPath: voicesURL.path) &&
                      fm.fileExists(atPath: tokensURL.path) &&
                      fm.fileExists(atPath: espeakDataURL.path)
        self.isModelReady = isReady
        print("🎯 KokoroTTSModelManager: Model readiness is \(isReady)")
    }

    // MARK: - Download & Extract
    func downloadModelIfNeeded() {
        guard !isModelReady && downloadProgress == nil else { return }

        downloadError = nil
        downloadProgress = 0.0

        let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2")!
        
        let session = URLSession(
            configuration: .default,
            delegate: SessionDelegate(manager: self),
            delegateQueue: nil
        )
        
        let task = session.downloadTask(with: url)
        self.activeDownloadTask = task
        task.resume()
        print("🎯 KokoroTTSModelManager: Started download task for Kokoro model")
    }

    fileprivate func updateProgress(_ fraction: Double) {
        self.downloadProgress = fraction
    }

    fileprivate func handleDownloadCompleted(tempURL: URL) {
        self.downloadProgress = nil
        
        let fm = FileManager.default
        let targetBz2URL = rootDirectoryURL.appendingPathComponent("kokoro-en-v0_19.tar.bz2")
        
        do {
            try fm.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
            try? fm.removeItem(at: targetBz2URL)
            try fm.moveItem(at: tempURL, to: targetBz2URL)
            
            print("🎯 KokoroTTSModelManager: Downloaded model tarball to \(targetBz2URL.path)")
            
            let rootPath = rootDirectoryURL.path
            let targetPath = targetBz2URL.path
            
            // Extract the tarball in the background
            Task.detached(priority: .userInitiated) {
                do {
                    print("🎯 KokoroTTSModelManager: Starting extraction...")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    process.arguments = ["-xf", targetPath, "-C", rootPath]
                    
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        print("🎯 KokoroTTSModelManager: Extraction successful!")
                        // Clean up the tarball
                        try? FileManager.default.removeItem(atPath: targetPath)
                        
                        await MainActor.run {
                            self.checkIfModelFilesExist()
                        }
                    } else {
                        print("⚠️ KokoroTTSModelManager: Tar process exited with status: \(process.terminationStatus)")
                        await MainActor.run {
                            self.downloadError = "Extraction failed."
                        }
                    }
                } catch {
                    print("⚠️ KokoroTTSModelManager: Failed to run extract process: \(error)")
                    await MainActor.run {
                        self.downloadError = "Extraction failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            print("⚠️ KokoroTTSModelManager: Failed to move temp file: \(error)")
            self.downloadError = "Save failed: \(error.localizedDescription)"
        }
    }

    fileprivate func handleDownloadError(_ error: Error) {
        self.downloadProgress = nil
        self.downloadError = error.localizedDescription
        print("⚠️ KokoroTTSModelManager: Download failed: \(error)")
    }
}

// MARK: - URLSessionDelegate
private class SessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let manager: KokoroTTSModelManager

    init(manager: KokoroTTSModelManager) {
        self.manager = manager
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            manager.updateProgress(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fileManager = FileManager.default
        let stableTempURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.bz2")
        do {
            try fileManager.copyItem(at: location, to: stableTempURL)
            Task { @MainActor in
                manager.handleDownloadCompleted(tempURL: stableTempURL)
            }
        } catch {
            print("⚠️ KokoroTTSModelManager: Failed to copy temp download to stable location: \(error)")
            Task { @MainActor in
                manager.handleDownloadError(error)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            Task { @MainActor in
                manager.handleDownloadError(error)
            }
        }
    }
}
