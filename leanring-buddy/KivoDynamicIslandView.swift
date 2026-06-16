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
//    • Top edge is FLAT (radius=0) so it looks glued to the screen top
//    • Bottom corners are rounded (radius=22) for a premium feel
//    • Header: [Kivo][Agent] toggle top-left | Status + keycaps top-right
//    • Kivo tab: Model + Voice pickers SIDE-BY-SIDE (height-compact)
//    • Agent tab: Placeholder
//    • Footer: Permission dots | Settings (⚙ opens centered sheet) | Quit
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

// MARK: - Top-Flat Notch Shape
// Top-left and top-right corners are SQUARE (radius=0) — the island looks
// physically attached to the screen top edge. Only bottom corners are rounded.
private struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height / 2)
        var path = Path()
        // Top-left → straight corner (glued to top of screen)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-right → straight corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right edge → bottom-right arc
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        // Bottom edge
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        // Bottom-left arc
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.closeSubpath()
        return path
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
    @State private var showSettingsSheet: Bool = false

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
            // ─── Background (flat-top notch shape for expanded, pill for collapsed) ───
            backgroundShape
                .animation(.smooth(duration: 0.30), value: islandState.isExpanded)

            // ─── Content ───
            if islandState.isExpanded {
                expandedIsland
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top))
                            .animation(.smooth(duration: 0.25).delay(0.06)),
                        removal: .opacity.animation(.easeOut(duration: 0.15))
                    ))
            } else {
                collapsedPill
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.14).delay(0.18)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))
                    ))
            }
        }
        // NOTE: The frame drives the VIEWPORT (window size) via KivoDynamicIslandManager.
        // The hosting view is pre-sized to the full expanded dimensions, so only
        // the window clips the visible area — no SwiftUI layout changes on resize.
        .frame(
            width:  islandState.isExpanded ? KivoDynamicIslandManager.expandedWidth  : KivoDynamicIslandManager.collapsedWidth,
            height: islandState.isExpanded ? KivoDynamicIslandManager.expandedHeight : KivoDynamicIslandManager.collapsedHeight
        )
        .animation(.smooth(duration: 0.30), value: islandState.isExpanded)
        .onAppear(perform: startAnimations)
        // ─── Settings sheet opens as a centred NSWindow (not a SwiftUI sheet) ───
        .onChange(of: showSettingsSheet) { _, isShowing in
            if isShowing { openSettingsWindow() }
        }
    }

    // MARK: - Background Shape

    @ViewBuilder
    private var backgroundShape: some View {
        if islandState.isExpanded {
            // Flat-top, rounded-bottom — "glued" to the screen edge
            NotchShape(bottomRadius: 22)
                .fill(Color.black.opacity(0.88))
                .background(
                    VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
                        .clipShape(NotchShape(bottomRadius: 22))
                )
                .overlay(
                    NotchShape(bottomRadius: 22)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.0), Color.white.opacity(0.12)],
                                startPoint: .top, endPoint: .bottom
                            ), lineWidth: 0.7
                        )
                )
                .shadow(color: accentColor.opacity(glowOpacity * 0.6), radius: glowRadius * 1.5, x: 0, y: 12)
                .shadow(color: .black.opacity(0.70), radius: 30, x: 0, y: 12)
        } else {
            // Collapsed pill — slightly rounded top corners acceptable since it
            // appears to hug the notch in the middle of the screen top
            PillShape(cornerRadius: 14)
                .fill(Color.black.opacity(0.90))
                .overlay(
                    PillShape(cornerRadius: 14)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            ), lineWidth: 0.6
                        )
                )
                .shadow(color: accentColor.opacity(glowOpacity), radius: glowRadius, x: 0, y: 2)
                .shadow(color: .black.opacity(0.50), radius: 10, x: 0, y: 4)
        }
    }

    // MARK: ─────────────── COLLAPSED PILL ───────────────

    private var collapsedPill: some View {
        HStack(spacing: 0) {
            stateIcon
                .padding(.leading, 9)
            Text(collapsedLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: 4)
            rightIndicator
                .padding(.trailing, 9)
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
                    .strokeBorder(accentColor.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
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
                .stroke(accentColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
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
            kivoOrAgentTabContent
            thinDivider
            expandedFooter
        }
        .frame(
            width:  KivoDynamicIslandManager.expandedWidth,
            height: KivoDynamicIslandManager.expandedHeight
        )
    }

    // MARK: Header Row

    private var expandedHeader: some View {
        HStack(spacing: 0) {
            // ── [Kivo] [Agent] toggle — top-left ──
            tabSwitcher

            Spacer()

            // ── Status text + keycaps — top-right ──
            HStack(spacing: 10) {
                Text(statusDescription)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(accentColor)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.2), value: statusDescription)

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
                        .stroke(accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(spinAngle))
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
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
            withAnimation(.smooth(duration: 0.20)) { selectedTab = tab }
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .medium))
                .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.38))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Group {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(DS.Colors.accent.opacity(0.22))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(DS.Colors.accent.opacity(0.35), lineWidth: 0.5)
                                )
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: Tab Content

    @ViewBuilder
    private var kivoOrAgentTabContent: some View {
        if selectedTab == .kivo {
            kivoTab
        } else {
            agentTab
        }
    }

    private var kivoTab: some View {
        // Model + Voice pickers SIDE-BY-SIDE to keep island height compact
        HStack(spacing: 12) {
            pickerRow(
                label: "Model",
                options: Self.modelOptions.map { ($0.id, $0.label) },
                selected: companionManager.selectedModel,
                onSelect: { companionManager.setSelectedModel($0) }
            )
            thinVerticalDivider
            pickerRow(
                label: "Voice",
                options: Self.voiceOptions.map { ($0, $0) },
                selected: companionManager.selectedVoice,
                onSelect: { companionManager.setSelectedVoice($0) }
            )
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickerRow(
        label: String,
        options: [(id: String, display: String)],
        selected: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(.white.opacity(0.28))
                .frame(width: 36, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(options, id: \.id) { opt in
                        pickerChip(label: opt.display, isOn: selected == opt.id) {
                            onSelect(opt.id)
                        }
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    private func pickerChip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                .foregroundColor(isOn ? .white : .white.opacity(0.42))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Group {
                        if isOn {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(DS.Colors.accent.opacity(0.22))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .stroke(DS.Colors.accent.opacity(0.40), lineWidth: 0.5)
                                )
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.smooth(duration: 0.18), value: isOn)
    }

    private var agentTab: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(.white.opacity(0.12))

            VStack(alignment: .leading, spacing: 3) {
                Text("No active background tasks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.38))
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

            // Settings — opens a centered panel for "Coming Soon" features
            Button {
                showSettingsSheet = true
            } label: {
                footerIconButton(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain).pointerCursor().help("Settings")

            // Quit
            Button { NSApplication.shared.terminate(nil) } label: {
                footerIconButton(systemName: "power")
            }
            .buttonStyle(.plain).pointerCursor().help("Quit Kivo Click")
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func footerIconButton(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.white.opacity(0.38))
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            )
    }

    private var permissionDots: some View {
        HStack(spacing: 7) {
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
                    // Use the accent blue for granted, a dim grey for missing — no green
                    .fill(granted ? DS.Colors.accent.opacity(0.70) : Color.white.opacity(0.10))
                    .frame(width: 4.5, height: 4.5)
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
                    .frame(width: 40, height: 3)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 8.5)).foregroundColor(.white.opacity(0.30))
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
            .padding(.vertical, 8)
    }

    // MARK: - Settings Window

    /// Opens a separate, centred NSWindow with a "Coming Soon" panel for the
    /// settings features (appearance, skills, login, etc.).
    private func openSettingsWindow() {
        showSettingsSheet = false

        let settingsView = KivoSettingsView()
        let hosting = NSHostingView(rootView: settingsView)
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: 480, height: 320))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 480, height: 320)),
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
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
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

    // Premium accent palette — no ugly greens, uses violet/amber/cyan
    private var accentColor: Color {
        switch companionManager.voiceState {
        case .idle:             return DS.Colors.accent                  // Kivo blue
        case .listening:        return Color(hex: "#A78BFA")             // Violet 400
        case .processing:       return Color(hex: "#FBBF24")             // Amber 400
        case .responding:       return Color(hex: "#22D3EE")             // Cyan 400
        case .waitingForAction: return Color(hex: "#FBBF24")             // Amber 400
        }
    }

    private var glowOpacity: Double {
        switch companionManager.voiceState {
        case .idle:      return 0.18
        case .listening: return 0.45
        default:         return 0.32
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

// MARK: - KivoSettingsView (opened in a separate centred NSWindow)

struct KivoSettingsView: View {
    var body: some View {
        ZStack {
            // Dark background
            Color(hex: "#0D0D12").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.accent)
                    Text("Kivo Click Settings")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.90))
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 18)

                Divider().opacity(0.15)

                // Settings tiles — all "Coming Soon"
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    settingsTile(icon: "paintbrush.fill",    title: "Appearance",   description: "Themes, colors, and layout")
                    settingsTile(icon: "cpu",                title: "AI Skills",    description: "Plugins and agent skills")
                    settingsTile(icon: "person.crop.circle", title: "Account",      description: "Login and cloud sync")
                    settingsTile(icon: "keyboard",           title: "Shortcuts",    description: "Custom hotkeys and triggers")
                    settingsTile(icon: "bell.fill",          title: "Notifications",description: "Alerts and sound settings")
                    settingsTile(icon: "shield.lefthalf.filled", title: "Privacy",  description: "Data and permissions")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                // Version badge
                Text("Kivo Click v0.1 — Settings coming soon")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.20))
                    .padding(.bottom, 16)
            }
        }
        .frame(width: 480, height: 320)
    }

    private func settingsTile(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.80))
                    Text("SOON")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(DS.Colors.accent.opacity(0.70))
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(DS.Colors.accent.opacity(0.15))
                        )
                }
                Text(description)
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.32))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
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
                    .animation(.easeInOut(duration: 0.12), value: level)
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
                withAnimation(.smooth(duration: 0.15)) { isHovered = hovering }
            }
    }
}
