//
//  KivoSoundFeedback.swift
//  leanring-buddy
//
//  Centralized sound feedback utility for Kivo Click.
//
//  All audio interactions go through this file so volumes are tuned in
//  one place and sounds never overlap badly.
//
//  Philosophy: sounds should be SUBTLE — noticeable enough to feel premium
//  but never jarring. Think AirPods connecting, not a notification alarm.
//
//  Uses:
//    - AVAudioPlayer for bundled mp3 files (enter.mp3 for activation)
//    - NSSound(named:) for macOS system sounds (Tink, Pop, Glass, Basso)
//

import AppKit
import AVFoundation
import Foundation

// MARK: - KivoSoundFeedback

enum KivoSoundFeedback {

    // Reusable AVAudioPlayer for the activation sound — kept alive so it
    // doesn't get deallocated mid-playback.
    private static var activationPlayer: AVAudioPlayer?
    private static var deactivationPlayer: AVAudioPlayer?

    // MARK: - Public API

    /// Called when ctrl+option is pressed — Kivo activates / starts listening.
    /// Plays an exciting, rising system chime (Hero) to confirm activation.
    static func playActivation() {
        playSystemSound(named: "Hero", volume: 0.45)
    }

    /// Called when ctrl+option is released — Kivo deactivates / stops listening.
    /// Plays a low, sad falling tone (Basso) to confirm deactivation/cancellation.
    static func playDeactivation() {
        playSystemSound(named: "Basso", volume: 0.40)
    }

    /// Called when a new agent task is created and added to the queue.
    /// A soft "pop" signals that something was spawned.
    static func playAgentStarted() {
        playSystemSound(named: "Pop", volume: 0.38)
    }

    /// Called when an agent task finishes successfully.
    /// A soft "glass" chime signals completion — pleasant and rewarding.
    static func playAgentCompleted() {
        playSystemSound(named: "Glass", volume: 0.50)
    }

    /// Called when an agent task fails.
    /// A low "basso" tone signals the failure without being alarming.
    static func playAgentFailed() {
        playSystemSound(named: "Basso", volume: 0.30)
    }

    /// Called when the user taps an orb in the top-right floating panel.
    /// Nearly inaudible — just enough to confirm the tap registered.
    static func playOrbTap() {
        playSystemSound(named: "Tink", volume: 0.18)
    }

    /// Called when the user switches between Home and Agents tabs.
    /// The quietest sound — more of a feel than a hear.
    static func playTabSwitch() {
        playSystemSound(named: "Tink", volume: 0.13)
    }

    // MARK: - Private Helpers

    /// Plays a named macOS system sound at the specified volume.
    /// NSSound.volume is instance-level so we make a copy each time.
    private static func playSystemSound(named soundName: String, volume: Float) {
        guard let sound = NSSound(named: soundName) else { return }

        // NSSound copies are needed because NSSound is not thread-safe to mutate
        // volume on the shared instance while it might be playing.
        guard let soundCopy = sound.copy() as? NSSound else { return }
        soundCopy.volume = volume
        soundCopy.play()
    }
}
