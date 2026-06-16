//
//  KivoDynamicIslandView.swift
//  leanring-buddy
//
//  The Dynamic Island SwiftUI view.
//
//  COLLAPSED (pill at top of screen):
//    • Idle        → blue bolt, soft breathing glow
//    • Listening   → green mic, pulsing ring, live waveform
//    • Processing  → amber spinning arc
//    • Responding  → sky-blue waveform icon
//
//  EXPANDED (on hover, drops down from top):
//    • Frosted glass background (NSVisualEffectView)
//    • Header: Kivo icon + name | [Kivo][Agent] tabs
//    • Kivo tab: status row, shortcut hint, model picker, voice picker
//    • Agent tab: placeholder
//    • Footer: permissions dots | ⚙ Settings | ⏻ Quit
//

import AppKit
import AVFoundation
import SwiftUI

// MARK: - VisualEffectView (NSVisualEffectView wrapper)

/// Wraps NSVisualEffectView to give the expanded panel its frosted-glass look.
/// blendingMode = .behindWindow so it blurs whatever is behind the panel on screen.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - KivoDynamicIslandView

struct KivoDynamicIslandView: View {

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var islandState: IslandState
    @ObservedObject private var modelManager = SherpaOnnxModelManager.shared

    @State private var selectedTab: IslandTab = .kivo
    @State private var breathingScale: CGFloat = 1.0
    @State private var spinAngle: Double = 0
    @State private var wavePhase: Double = 0

    enum IslandTab: String, CaseIterable { case kivo = "Kivo"; case agent = "Agent" }

    private static let modelOptions: [(id: String, label: String)] = [
        ("gemini-3.5-flash",               "Gemini 2.5"),
        ("gemini-2.5-flash-preview-05-20", "Flash"),
        ("llama-3.3-70b-versatile",        "Hybrid")
    ]
    private static let voiceOptions = ["Aoede", "Puck", "Hannah", "Daniel"]

    private var allPermissionsGranted: Bool {
        companionManager.hasMicrophonePermission
            && companionManager.hasAccessibilityPermission
            && companionManager.hasScreenRecordingPermission
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            if islandState.isExpanded {
                expandedIsland
            } else {
                collapsedPill
            }
        }
        .frame(
            width:  islandState.isExpanded ? KivoDynamicIslandManager.expandedWidth  : KivoDynamicIslandManager.collapsedWidth,
            height: islandState.isExpanded ? KivoDynamicIslandManager.expandedHeight : KivoDynamicIslandManager.collapsedHeight
        )
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: islandState.isExpanded)
        .onAppear(perform: startAnimations)
    }

    // MARK: ─────────────── COLLAPSED PILL ───────────────

    private var collapsedPill: some View {
        ZStack {
            // Pill background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            ), lineWidth: 0.6
                        )
                )
                // State-coloured glow — changes intensity with voice state
                .shadow(color: accentColor.opacity(glowOpacity), radius: glowRadius, x: 0, y: 2)
                .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 4)

            HStack(spacing: 0) {
                // Icon area
                stateIcon
                    .padding(.leading, 10)

                // Label
                Text(collapsedLabel)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
                    .padding(.leading, 6)

                Spacer(minLength: 4)

                // Right indicator
                rightIndicator
                    .padding(.trailing, 10)
            }
        }
        .frame(
            width:  KivoDynamicIslandManager.collapsedWidth,
            height: KivoDynamicIslandManager.collapsedHeight
        )
        .transition(.asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.10).delay(0.22)),
            removal:   .opacity.animation(.easeOut(duration: 0.08))
        ))
    }

    // State icon with animated backing circle
    private var stateIcon: some View {
        ZStack {
            // Pulsing ring — only during listening
            if companionManager.voiceState == .listening {
                Circle()
                    .strokeBorder(accentColor.opacity(0.40), lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                    .scaleEffect(breathingScale)
            }
            Circle()
                .fill(accentColor.opacity(0.20))
                .frame(width: 18, height: 18)
            Image(systemName: iconName)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(accentColor)
                .rotationEffect(
                    companionManager.voiceState == .processing ? .degrees(spinAngle) : .degrees(0)
                )
        }
    }

    // Right side of the collapsed pill
    @ViewBuilder
    private var rightIndicator: some View {
        switch companionManager.voiceState {
        case .listening:
            // Live waveform bars
            MiniWaveform(level: companionManager.currentAudioPowerLevel,
                         phase: wavePhase, color: accentColor)
                .frame(width: 28, height: 12)
        case .processing, .waitingForAction:
            // Spinning arc
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(spinAngle))
        default:
            // Breathing dot
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)
                .scaleEffect(breathingScale)
        }
    }

    // MARK: ─────────────── EXPANDED ISLAND ───────────────

    private var expandedIsland: some View {
        ZStack {
            // Frosted glass base
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .background(
                    VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            ), lineWidth: 0.6
                        )
                )
                .shadow(color: .black.opacity(0.70), radius: 28, x: 0, y: 10)

            // Content
            VStack(spacing: 0) {
                expandedHeader
                islandDivider
                if selectedTab == .kivo { kivoTab } else { agentTab }
                islandDivider
                expandedFooter
            }
        }
        .frame(
            width:  KivoDynamicIslandManager.expandedWidth,
            height: KivoDynamicIslandManager.expandedHeight
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                .animation(.spring(response: 0.30, dampingFraction: 0.80).delay(0.04)),
            removal: .opacity.animation(.easeOut(duration: 0.14))
        ))
    }

    // MARK: Header

    private var expandedHeader: some View {
        HStack(spacing: 0) {
            // Kivo branding (left)
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(accentColor.opacity(0.22)).frame(width: 24, height: 24)
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(accentColor)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Kivo Click")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                    Text(statusDescription)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(accentColor.opacity(0.85))
                }
            }

            Spacer()

            // Tab switcher (centre-right)
            HStack(spacing: 2) {
                ForEach(IslandTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func tabButton(_ tab: IslandTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.80)) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.38))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(
                    Group {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(DS.Colors.accent.opacity(0.30))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(DS.Colors.accent.opacity(0.50), lineWidth: 0.5)
                                )
                        }
                    }
                )
        }
        .buttonStyle(.plain).pointerCursor()
    }

    // MARK: Kivo Tab

    private var kivoTab: some View {
        VStack(spacing: 0) {
            // Shortcut hint row
            shortcutHintRow
                .padding(.horizontal, 16).padding(.vertical, 10)

            islandDivider

            // Model + Voice pickers
            VStack(spacing: 7) {
                pickerRow(label: "Model", options: Self.modelOptions.map { ($0.id, $0.label) },
                          selected: companionManager.selectedModel,
                          onSelect: { companionManager.setSelectedModel($0) })
                pickerRow(label: "Voice",
                          options: Self.voiceOptions.map { ($0, $0) },
                          selected: companionManager.selectedVoice,
                          onSelect: { companionManager.setSelectedVoice($0) })
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Shortcut hint — the most important action call-out
    private var shortcutHintRow: some View {
        HStack(spacing: 10) {
            // State icon + description
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accentColor)
                    .rotationEffect(
                        companionManager.voiceState == .processing ? .degrees(spinAngle) : .degrees(0)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusDescription)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))

                    if companionManager.voiceState == .idle {
                        Text("Push to talk: hold and speak")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.38))
                    }
                }
            }

            Spacer()

            // Shortcut badge (idle only)
            if companionManager.voiceState == .idle {
                shortcutBadge
            } else if companionManager.voiceState == .listening {
                // Live waveform
                MiniWaveform(level: companionManager.currentAudioPowerLevel,
                             phase: wavePhase, color: accentColor)
                    .frame(width: 44, height: 18)
            }
        }
    }

    private var shortcutBadge: some View {
        HStack(spacing: 3) {
            keyCapView("⌃")
            keyCapView("⌥")
        }
    }

    private func keyCapView(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.65))
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.30), radius: 2, x: 0, y: 1)
            )
    }

    private func pickerRow(label: String,
                           options: [(id: String, display: String)],
                           selected: String,
                           onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.36))
                .frame(width: 36, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(options, id: \.id) { opt in
                        pillToggle(label: opt.display, isOn: selected == opt.id) {
                            onSelect(opt.id)
                        }
                    }
                }
            }
        }
    }

    private func pillToggle(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .foregroundColor(isOn ? .white : .white.opacity(0.48))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isOn ? DS.Colors.accent.opacity(0.32) : Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isOn ? DS.Colors.accent.opacity(0.55) : Color.clear,
                                        lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain).pointerCursor()
        .animation(.spring(response: 0.20, dampingFraction: 0.80), value: isOn)
    }

    // MARK: Agent Tab

    private var agentTab: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "cpu.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(.white.opacity(0.12))
            Text("No Active Agents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
            Text("Say 'Create a React app' and Kivo\nwill run it as a background task.")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.18))
                .multilineTextAlignment(.center).lineSpacing(2)
            Spacer()
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 16)
    }

    // MARK: Footer (permissions + settings + quit)

    private var expandedFooter: some View {
        HStack(spacing: 10) {
            // Permissions dots
            permissionDots

            Spacer()

            // WhisperKit download (only if needed)
            if !modelManager.isModelReady {
                whisperIndicator
            }

            // Settings gear — placeholder (opens System Settings as fallback)
            Button {
                if let url = URL(string: "x-apple.systempreferences:") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain).pointerCursor().help("Settings")

            // Quit
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain).pointerCursor().help("Quit Kivo Click")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var permissionDots: some View {
        HStack(spacing: 5) {
            permDot(granted: companionManager.hasMicrophonePermission, label: "Mic") {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
            permDot(granted: companionManager.hasAccessibilityPermission, label: "AX") {
                WindowPositionManager.requestAccessibilityPermission()
            }
            permDot(granted: companionManager.hasScreenRecordingPermission, label: "Screen") {
                WindowPositionManager.requestScreenRecordingPermission()
            }
        }
    }

    private func permDot(granted: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Circle()
                    .fill(granted ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.28))
            }
        }
        .buttonStyle(.plain).pointerCursor()
        .help(granted ? "\(label) granted" : "Grant \(label) permission")
    }

    private var whisperIndicator: some View {
        Group {
            if let progress = modelManager.downloadProgress {
                HStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(DS.Colors.accent)
                                .frame(width: geo.size.width * CGFloat(progress))
                                .animation(.linear(duration: 0.15), value: progress)
                        }
                    }
                    .frame(width: 46, height: 4)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.35))
                }
            } else {
                Button {
                    Task { await SherpaOnnxModelManager.shared.downloadModelIfNeeded() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: modelManager.downloadError != nil
                              ? "arrow.clockwise" : "arrow.down.circle").font(.system(size: 9))
                        Text(modelManager.downloadError != nil ? "Retry" : "Get AI")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.accentText)
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
    }

    // MARK: - Shared UI

    private var islandDivider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
    }

    // MARK: - Animation Drivers

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            breathingScale = 1.08
        }
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            spinAngle = 360
        }
        withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
            wavePhase = 1.0
        }
    }

    // MARK: - State Properties

    private var iconName: String {
        switch companionManager.voiceState {
        case .idle:             return "bolt.fill"
        case .listening:        return "mic.fill"
        case .processing:       return "arrow.triangle.2.circlepath"
        case .responding:       return "waveform"
        case .waitingForAction: return "hand.tap.fill"
        }
    }

    private var collapsedLabel: String {
        switch companionManager.voiceState {
        case .idle:             return "Kivo Click"
        case .listening:        return "Listening…"
        case .processing:       return "Thinking…"
        case .responding:       return "Speaking…"
        case .waitingForAction: return "Your turn…"
        }
    }

    private var statusDescription: String {
        switch companionManager.voiceState {
        case .idle:             return allPermissionsGranted ? "Hold ⌃⌥ to talk" : "Permissions needed"
        case .listening:        return "Listening…"
        case .processing:       return "Thinking…"
        case .responding:       return "Speaking…"
        case .waitingForAction: return "Waiting for your action"
        }
    }

    private var accentColor: Color {
        switch companionManager.voiceState {
        case .idle:             return DS.Colors.accent
        case .listening:        return Color(hue: 0.37, saturation: 0.72, brightness: 0.90)
        case .processing:       return Color(hue: 0.10, saturation: 0.88, brightness: 0.98)
        case .responding:       return Color(hue: 0.57, saturation: 0.70, brightness: 1.00)
        case .waitingForAction: return Color(hue: 0.10, saturation: 0.88, brightness: 0.98)
        }
    }

    private var glowOpacity: Double {
        switch companionManager.voiceState {
        case .idle: return 0.20
        case .listening: return 0.55
        case .processing: return 0.45
        default: return 0.40
        }
    }

    private var glowRadius: CGFloat {
        switch companionManager.voiceState {
        case .idle: return 8
        case .listening: return 18
        case .processing: return 14
        default: return 14
        }
    }
}

// MARK: - MiniWaveform

private struct MiniWaveform: View {
    let level: CGFloat
    let phase: Double
    let color: Color
    private let bars = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 2.5, height: barH(i))
            }
        }
    }

    private func barH(_ i: Int) -> CGFloat {
        let base: CGFloat = 2
        let maxH: CGFloat = 14
        let p = max(0.10, level)
        let wave = CGFloat(sin(Double(i) * 1.2 + phase * .pi * 2) * 0.5 + 0.5)
        return base + (maxH - base) * p * wave
    }
}
