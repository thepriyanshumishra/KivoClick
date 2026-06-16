//
//  KivoDynamicIslandView.swift
//  leanring-buddy
//
//  The Dynamic Island SwiftUI view.
//
//  COLLAPSED (pill at top of screen):
//    • Idle        → blue bolt, soft breathing glow
//    • Listening   → violet mic, pulsing ring, live waveform
//    • Processing  → amber spinning arc
//    • Responding  → cyan waveform
//
//  EXPANDED (on hover, drops down from top):
//    • Flat top edge (NotchShape) — appears glued to the screen edge
//    • Bottom corners rounded (22pt)
//    • Header: [Kivo][Agent] toggle top-left | Status + keycaps top-right
//    • Kivo tab: Two-row model picker + two-row voice picker side-by-side
//    • Agent tab: Placeholder
//    • Footer: Permission dots | Settings (⚙ centered window) | Quit
//

import AppKit
import AVFoundation
import SwiftUI

// MARK: - VisualEffectView

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

// MARK: - NotchShape (flat top, rounded bottom)
// Top corners are SQUARE so the expanded island looks physically attached to
// the screen top edge, exactly like the system camera notch.
// Only bottom corners carry a radius for the premium "dropped card" look.
private struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))          // top-left (flat)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))       // top-right (flat)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))   // right edge
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))   // bottom edge
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Model Definition

private struct AIModel {
    let id: String
    let displayName: String
    let subtitle: String
}

// MARK: - Voice Definition

private enum VoiceProvider { case gemini, orpheus }

private struct AIVoice {
    let id: String
    let displayName: String
    let gender: String   // "M" or "F"
    let provider: VoiceProvider
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
    @State private var showSettingsSheet: Bool = false

    enum IslandTab: String, CaseIterable { case kivo = "Kivo"; case agent = "Agent" }

    // ── Model catalogue ──────────────────────────────────────────────────────
    // Row 1 (direct models): Gemini 2.5 → Balanced, Gemini 3.5 → Smartest
    // Row 2 (hybrid):        Llama 4 → Most Capable (vision via Llama 4 Scout
    //                        + reasoning via Llama 3.3 70B)
    private static let geminiModels: [AIModel] = [
        AIModel(id: "gemini-2.5-flash-preview-05-20", displayName: "Gemini 2.5", subtitle: "Balanced"),
        AIModel(id: "gemini-3.5-flash",               displayName: "Gemini 3.5", subtitle: "Smartest"),
    ]
    private static let hybridModels: [AIModel] = [
        AIModel(id: "llama-3.3-70b-versatile",        displayName: "Llama 4",    subtitle: "Most Capable"),
    ]

    // ── Voice catalogue ──────────────────────────────────────────────────────
    // Row 1 (Gemini TTS): Aoede (F), Puck (M)
    // Row 2 (Orpheus TTS, deeper/richer): Hannah (F), Daniel (M)
    private static let geminiVoices: [AIVoice] = [
        AIVoice(id: "Aoede",   displayName: "Aoede",  gender: "F", provider: .gemini),
        AIVoice(id: "Puck",    displayName: "Puck",   gender: "M", provider: .gemini),
    ]
    private static let orpheusVoices: [AIVoice] = [
        AIVoice(id: "Hannah",  displayName: "Hannah", gender: "F", provider: .orpheus),
        AIVoice(id: "Daniel",  displayName: "Daniel", gender: "M", provider: .orpheus),
    ]

    private var allPermissionsGranted: Bool {
        companionManager.hasMicrophonePermission
            && companionManager.hasAccessibilityPermission
            && companionManager.hasScreenRecordingPermission
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            backgroundShape
            contentLayer
        }
        .frame(
            width:  islandState.isExpanded ? KivoDynamicIslandManager.expandedWidth  : KivoDynamicIslandManager.collapsedWidth,
            height: islandState.isExpanded ? KivoDynamicIslandManager.expandedHeight : KivoDynamicIslandManager.collapsedHeight
        )
        .onAppear(perform: startAnimations)
        .onChange(of: showSettingsSheet) { _, isShowing in
            if isShowing { openSettingsWindow() }
        }
    }

    // MARK: - Background Layer

    @ViewBuilder
    private var backgroundShape: some View {
        if islandState.isExpanded {
            // Flat-top card — the notch shape
            NotchShape(bottomRadius: 20)
                .fill(Color.black.opacity(0.90))
                .background(
                    VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
                        .clipShape(NotchShape(bottomRadius: 20))
                )
                .overlay(
                    // Only stroke the bottom and sides — the top is invisible (flush with screen)
                    NotchShape(bottomRadius: 20)
                        .stroke(
                            LinearGradient(
                                colors: [Color.clear, Color.white.opacity(0.10)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.7
                        )
                )
                .shadow(color: accentColor.opacity(0.20), radius: 18, x: 0, y: 14)
                .shadow(color: .black.opacity(0.65), radius: 32, x: 0, y: 14)
        } else {
            // Collapsed pill — small, centered, glowing
            PillShape(cornerRadius: 13)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    PillShape(cornerRadius: 13)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.6
                        )
                )
                .shadow(color: accentColor.opacity(glowOpacity), radius: glowRadius, x: 0, y: 3)
                .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)
        }
    }

    // MARK: - Content Layer

    @ViewBuilder
    private var contentLayer: some View {
        if islandState.isExpanded {
            expandedIsland
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .move(edge: .top))
                            .animation(.spring(response: 0.32, dampingFraction: 0.82).delay(0.07)),
                        removal: .opacity
                            .animation(.easeOut(duration: 0.14))
                    )
                )
        } else {
            collapsedPill
                .transition(
                    .asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.14).delay(0.18)),
                        removal:   .opacity.animation(.easeOut(duration: 0.08))
                    )
                )
        }
    }

    // MARK: ─────────────── COLLAPSED PILL ───────────────

    private var collapsedPill: some View {
        HStack(spacing: 0) {
            stateIcon.padding(.leading, 9)
            Text(collapsedLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: 4)
            rightIndicator.padding(.trailing, 9)
        }
        .frame(
            width:  KivoDynamicIslandManager.collapsedWidth,
            height: KivoDynamicIslandManager.collapsedHeight
        )
    }

    private var stateIcon: some View {
        ZStack {
            if companionManager.voiceState == .listening {
                Circle()
                    .strokeBorder(accentColor.opacity(0.38), lineWidth: 1.4)
                    .frame(width: 20, height: 20)
                    .scaleEffect(breathingScale)
            }
            Circle()
                .fill(accentColor.opacity(0.18))
                .frame(width: 15, height: 15)
            Image(systemName: iconName)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(accentColor)
                .rotationEffect(
                    companionManager.voiceState == .processing ? .degrees(spinAngle) : .degrees(0)
                )
        }
    }

    @ViewBuilder
    private var rightIndicator: some View {
        switch companionManager.voiceState {
        case .listening:
            MiniWaveform(level: companionManager.currentAudioPowerLevel, phase: wavePhase, color: accentColor)
                .frame(width: 26, height: 10)
        case .processing, .waitingForAction:
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(spinAngle))
        default:
            Circle()
                .fill(accentColor)
                .frame(width: 5, height: 5)
                .scaleEffect(breathingScale)
        }
    }

    // MARK: ─────────────── EXPANDED ISLAND ───────────────

    private var expandedIsland: some View {
        VStack(spacing: 0) {
            expandedHeader
            thinDivider
            kivoOrAgentContent
            thinDivider
            expandedFooter
        }
        .frame(
            width:  KivoDynamicIslandManager.expandedWidth,
            height: KivoDynamicIslandManager.expandedHeight
        )
    }

    // MARK: Header

    private var expandedHeader: some View {
        HStack(spacing: 0) {
            // ── [Kivo] [Agent] segmented toggle — top-left ──────────────────
            tabSwitcher

            Spacer()

            // ── Live status + shortcut keys — top-right ──────────────────────
            HStack(spacing: 10) {
                statusLabel
                shortcutAccessory
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var statusLabel: some View {
        Text(statusDescription)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(accentColor)
            .contentTransition(.numericText())
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: statusDescription)
    }

    @ViewBuilder
    private var shortcutAccessory: some View {
        switch companionManager.voiceState {
        case .idle:
            HStack(spacing: 3) {
                HoverableKeyCapView(key: "⌃")
                HoverableKeyCapView(key: "⌥")
            }
        case .listening:
            MiniWaveform(level: companionManager.currentAudioPowerLevel, phase: wavePhase, color: accentColor)
                .frame(width: 30, height: 11)
        case .processing:
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(spinAngle))
        default:
            EmptyView()
        }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(IslandTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
    }

    private func tabButton(_ tab: IslandTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                selectedTab = tab
            }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .medium))
                .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.38))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selectedTabBackground(for: tab))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private func selectedTabBackground(for tab: IslandTab) -> some View {
        if selectedTab == tab {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.accent.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.accent.opacity(0.35), lineWidth: 0.5)
                )
        } else {
            Color.clear
        }
    }

    // MARK: Tab Content

    @ViewBuilder
    private var kivoOrAgentContent: some View {
        if selectedTab == .kivo {
            kivoTab
        } else {
            agentTab
        }
    }

    // MARK: Kivo Tab — two-row model + two-row voice side by side

    private var kivoTab: some View {
        HStack(spacing: 0) {
            // Left column: Model picker
            modelPickerColumn
                .frame(maxWidth: .infinity)

            thinVerticalDivider

            // Right column: Voice picker
            voicePickerColumn
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Model Picker ─────────────────────────────────────────────────────────

    private var modelPickerColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1 — Gemini models
            pickerRowHeader("Gemini")
            HStack(spacing: 4) {
                ForEach(Self.geminiModels, id: \.id) { model in
                    modelChip(model: model, isOn: companionManager.selectedModel == model.id) {
                        companionManager.setSelectedModel(model.id)
                    }
                }
            }

            // Row 2 — Hybrid/Llama
            pickerRowHeader("Hybrid")
            HStack(spacing: 4) {
                ForEach(Self.hybridModels, id: \.id) { model in
                    modelChip(model: model, isOn: companionManager.selectedModel == model.id) {
                        companionManager.setSelectedModel(model.id)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    private func pickerRowHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.22))
            .tracking(0.8)
    }

    private func modelChip(model: AIModel, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 10.5, weight: isOn ? .semibold : .medium))
                    .foregroundColor(isOn ? .white : .white.opacity(0.50))
                Text(model.subtitle)
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundColor(isOn ? accentColor.opacity(0.80) : .white.opacity(0.22))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(chipBackground(isOn: isOn))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isOn)
    }

    // ── Voice Picker ─────────────────────────────────────────────────────────

    private var voicePickerColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1 — Gemini TTS voices
            pickerRowHeader("Gemini Voices")
            HStack(spacing: 4) {
                ForEach(Self.geminiVoices, id: \.id) { voice in
                    voiceChip(voice: voice, isOn: companionManager.selectedVoice == voice.id) {
                        companionManager.setSelectedVoice(voice.id)
                    }
                }
            }

            // Row 2 — Orpheus TTS voices (richer, more human)
            pickerRowHeader("Orpheus Voices")
            HStack(spacing: 4) {
                ForEach(Self.orpheusVoices, id: \.id) { voice in
                    voiceChip(voice: voice, isOn: companionManager.selectedVoice == voice.id) {
                        companionManager.setSelectedVoice(voice.id)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    private func voiceChip(voice: AIVoice, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.displayName)
                        .font(.system(size: 10.5, weight: isOn ? .semibold : .medium))
                        .foregroundColor(isOn ? .white : .white.opacity(0.50))
                }
                // Gender badge
                Text(voice.gender)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundColor(isOn ? accentColor.opacity(0.80) : .white.opacity(0.20))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(isOn ? accentColor.opacity(0.18) : Color.white.opacity(0.06))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(chipBackground(isOn: isOn))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isOn)
    }

    // Shared chip background — selected = accent tinted card, unselected = subtle
    @ViewBuilder
    private func chipBackground(isOn: Bool) -> some View {
        if isOn {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.accent.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.accent.opacity(0.32), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        }
    }

    // MARK: Agent Tab

    private var agentTab: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 36, height: 36)
                Image(systemName: "cpu.fill")
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(.white.opacity(0.20))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("No active background tasks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.40))
                Text("Say 'Create a React app' and Kivo will orchestrate it.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.22))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var expandedFooter: some View {
        HStack(spacing: 10) {
            permissionDots
            Spacer()

            if !modelManager.isModelReady {
                whisperIndicator
            }

            // Settings — opens a centered window listing features coming soon
            Button { showSettingsSheet = true } label: {
                footerIconButton(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain).pointerCursor().help("Settings")

            Button { NSApplication.shared.terminate(nil) } label: {
                footerIconButton(systemName: "power")
            }
            .buttonStyle(.plain).pointerCursor().help("Quit Kivo Click")
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func footerIconButton(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.36))
            .frame(width: 21, height: 21)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.055))
                    .overlay(Circle().stroke(Color.white.opacity(0.09), lineWidth: 0.5))
            )
    }

    private var permissionDots: some View {
        HStack(spacing: 8) {
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
            HStack(spacing: 4) {
                Circle()
                    .fill(granted ? DS.Colors.accent.opacity(0.75) : Color.white.opacity(0.10))
                    .frame(width: 4, height: 4)
                Text(label)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(granted ? .white.opacity(0.50) : .white.opacity(0.18))
            }
        }
        .buttonStyle(.plain).pointerCursor()
        .help(granted ? "\(label) granted" : "Grant \(label) permission")
    }

    private var whisperIndicator: some View {
        Group {
            if let progress = modelManager.downloadProgress {
                HStack(spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.07))
                            Capsule().fill(DS.Colors.accent)
                                .frame(width: geo.size.width * CGFloat(progress))
                                .animation(.linear(duration: 0.15), value: progress)
                        }
                    }
                    .frame(width: 38, height: 3)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 8.5)).foregroundColor(.white.opacity(0.28))
                }
            } else {
                Button {
                    Task { await SherpaOnnxModelManager.shared.downloadModelIfNeeded() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: modelManager.downloadError != nil ? "arrow.clockwise" : "arrow.down.circle")
                            .font(.system(size: 8.5))
                        Text(modelManager.downloadError != nil ? "Retry" : "Get AI")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.accentText)
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
    }

    // MARK: - Shared UI

    private var thinDivider: some View {
        Rectangle().fill(Color.white.opacity(0.055)).frame(height: 0.5)
    }

    private var thinVerticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 0.5)
            .padding(.vertical, 10)
    }

    // MARK: - Settings Window

    private func openSettingsWindow() {
        showSettingsSheet = false

        let settingsView = KivoSettingsView()
        let hosting = NSHostingView(rootView: settingsView)
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: 500, height: 340))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 500, height: 340)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kivo Click — Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(DS.Colors.surface1)
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.level = .floating
    }

    // MARK: - Animation Drivers

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            breathingScale = 1.08
        }
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            spinAngle = 360
        }
        withAnimation(.linear(duration: 0.90).repeatForever(autoreverses: false)) {
            wavePhase = 1.0
        }
    }

    // MARK: - State Helpers

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
        case .waitingForAction: return "Waiting for action"
        }
    }

    // Premium accent palette — violet/amber/cyan, no generic greens
    private var accentColor: Color {
        switch companionManager.voiceState {
        case .idle:             return DS.Colors.accent         // Kivo blue
        case .listening:        return Color(hex: "#A78BFA")    // Violet 400
        case .processing:       return Color(hex: "#FBBF24")    // Amber 400
        case .responding:       return Color(hex: "#22D3EE")    // Cyan 400
        case .waitingForAction: return Color(hex: "#FBBF24")    // Amber 400
        }
    }

    private var glowOpacity: Double {
        switch companionManager.voiceState {
        case .idle:      return 0.18
        case .listening: return 0.48
        default:         return 0.30
        }
    }

    private var glowRadius: CGFloat {
        switch companionManager.voiceState {
        case .idle:      return 7
        case .listening: return 16
        default:         return 12
        }
    }
}

// MARK: - KivoSettingsView

struct KivoSettingsView: View {
    var body: some View {
        ZStack {
            Color(hex: "#0D0D12").ignoresSafeArea()

            VStack(spacing: 0) {
                // Title bar area
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.accent)
                        Text("Kivo Click Settings")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.90))
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                    .padding(.horizontal, 0)

                // Settings grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    settingsTile(icon: "paintbrush.fill",         title: "Appearance",    description: "Themes, accent colors, layout")
                    settingsTile(icon: "cpu",                     title: "AI Skills",     description: "Plugins and agent extensions")
                    settingsTile(icon: "person.crop.circle.fill", title: "Account",       description: "Login and cloud sync")
                    settingsTile(icon: "keyboard",                title: "Shortcuts",     description: "Custom hotkeys and triggers")
                    settingsTile(icon: "bell.badge.fill",         title: "Notifications", description: "Alerts and sound settings")
                    settingsTile(icon: "shield.lefthalf.filled",  title: "Privacy",       description: "Data and permission controls")
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)

                Spacer()

                Text("Kivo Click v0.1 — Features coming soon")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.18))
                    .padding(.bottom, 14)
            }
        }
        .frame(width: 500, height: 340)
    }

    private func settingsTile(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                    Text("SOON")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(DS.Colors.accent.opacity(0.70))
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Capsule().fill(DS.Colors.accent.opacity(0.14)))
                }
                Text(description)
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.30))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.042))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        )
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
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(color)
                    .frame(width: 2.2, height: barH(i))
            }
        }
    }

    private func barH(_ i: Int) -> CGFloat {
        let base: CGFloat = 2
        let maxH: CGFloat = 10
        let p = max(0.10, level)
        let wave = CGFloat(sin(Double(i) * 1.2 + phase * .pi * 2) * 0.5 + 0.5)
        return base + (maxH - base) * p * wave
    }
}

// MARK: - HoverableKeyCapView

private struct HoverableKeyCapView: View {
    let key: String
    @State private var isHovered = false

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.58))
            .frame(width: 17, height: 17)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.14 : 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(isHovered ? 0.24 : 0.14), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 1)
            )
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                    isHovered = hovering
                }
            }
    }
}
