//
//  FloatingAgentOrbsView.swift
//  leanring-buddy
//
//  SwiftUI views for the top-right desktop agent orb stack.
//
//  LAYOUT (top-right corner, 8pt from right edge, 8pt below menu bar):
//
//    ┌─────────────────────────────┐
//    │ ● Hello World Site  Running │  ← green orb
//    ├─────────────────────────────┤
//    │ ● Build React App   Done    │  ← pink orb
//    ├─────────────────────────────┤
//    │ ● Git Push          Pending │  ← blue orb
//    └─────────────────────────────┘
//
//  Each orb has an independent staggered sine-wave float so they feel
//  organic, not mechanical. Clicking an orb plays a tap sound and shows
//  a detail popover anchored to that orb.
//

import AppKit
import SwiftUI

// MARK: - FloatingAgentOrbsView

/// Root view placed inside the top-right NSPanel.
/// Shows one AgentOrbRow per active task, stacked vertically.
struct FloatingAgentOrbsView: View {

    var agentManager: AgentManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(agentManager.activeTasks.enumerated()), id: \.element.id) { index, task in
                AgentOrbRow(task: task, orbIndex: index)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        // Animate the stack when tasks are added or removed
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: agentManager.activeTasks.map { $0.id })
    }
}

// MARK: - AgentOrbRow

/// A single floating colored orb pill for one agent task.
/// Has an independent sine-wave Y-float animation to feel premium.
private struct AgentOrbRow: View {

    var task: AgentTask
    let orbIndex: Int

    // Controls whether the detail card is shown for this orb
    @State private var isShowingDetailCard: Bool = false

    // The Y-offset driven by the float animation timer
    @State private var floatYOffset: CGFloat = 0

    // A local timer drives the float — each orb runs its own phase so they
    // don't all bob in sync (staggered by orbIndex * 0.6 radians).
    @State private var floatTimer: Timer? = nil
    @State private var floatTime: Double = 0
    @State private var isHovered: Bool = false

    // Popping animation states
    @State private var playPoppingScale: CGFloat = 1.0
    @State private var showPoppingParticles: Bool = false

    // Amplitude and speed of the float
    private let floatAmplitude: CGFloat = 3.0
    private let floatSpeed: Double = 0.8      // radians per timer tick
    private let timerInterval: Double = 1.0 / 30.0  // ~30 fps

    var body: some View {
        orbPill
            .popover(
                isPresented: $isShowingDetailCard,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .leading
            ) {
                AgentDetailCard(task: task, floatTime: floatTime, isPresented: $isShowingDetailCard)
            }
            .offset(y: floatYOffset)
            .onAppear { startFloatAnimation() }
            .onDisappear { stopFloatAnimation() }
            .onChange(of: task.overallStatus) { oldValue, newValue in
                if newValue == .done {
                    // Play complete pop animation
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) {
                        playPoppingScale = 1.45
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showPoppingParticles = true
                        withAnimation(.easeOut(duration: 0.25)) {
                            playPoppingScale = 0.0
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        AgentManager.shared.removeTask(id: task.id)
                    }
                }
            }
    }

    // MARK: Orb Pill

    private var orbPill: some View {
        Button {
            KivoSoundFeedback.playOrbTap()
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isShowingDetailCard.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                // Morphing droplet accent dot with scale-up popping animation support
                ZStack {
                    MorphingDroplet(time: floatTime)
                        .fill(task.color)
                        .frame(width: 8, height: 8)
                        .shadow(color: task.color.opacity(0.60), radius: 4, x: 0, y: 0)
                        .scaleEffect(playPoppingScale)
                    
                    if showPoppingParticles {
                        OrbPoppingParticles(color: task.color)
                    }
                }

                // Agent title — truncated so long names don't overflow
                Text(task.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)

                Spacer(minLength: 4)

                // Status badge
                statusBadge
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(orbBackground)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .frame(width: 240)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                isHovered = hovering
            }
        }
        .scaleEffect(isHovered ? 1.04 : 1.0)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            // Animated dot for "Running"
            if task.overallStatus == .running {
                Circle()
                    .fill(task.statusBadgeColor)
                    .frame(width: 4, height: 4)
            }

            Text(task.statusBadgeText)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundColor(task.statusBadgeColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            Capsule()
                .fill(task.statusBadgeColor.opacity(0.15))
                .overlay(
                    Capsule()
                        .stroke(task.statusBadgeColor.opacity(0.30), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var orbBackground: some View {
        // Dark glass pill with the agent's color subtly tinting the border
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(hex: "#0E0E12").opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                task.color.opacity(0.40),
                                task.color.opacity(0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: task.color.opacity(0.18), radius: 8, x: 0, y: 2)
            .shadow(color: .black.opacity(0.55), radius: 12, x: 0, y: 4)
    }

    // MARK: Float Animation

    /// Starts a repeating timer that drives the sine-wave Y-offset.
    /// Each orb gets a unique starting phase so they float out of sync.
    private func startFloatAnimation() {
        // Stagger the start phase by orbIndex so orbs float independently
        floatTime = Double(orbIndex) * 0.6

        floatTimer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { _ in
            floatTime += floatSpeed * timerInterval
            // Smooth sine wave: amplitude ±3pt, ~4 second full cycle
            let newOffset = sin(floatTime) * Double(floatAmplitude)
            DispatchQueue.main.async {
                withAnimation(.linear(duration: timerInterval)) {
                    floatYOffset = CGFloat(newOffset)
                }
            }
        }
    }

    private func stopFloatAnimation() {
        floatTimer?.invalidate()
        floatTimer = nil
    }
}

// MARK: - AgentDetailCard

/// Popover that appears when the user clicks an orb.
/// Shows: task title, status badge, subtask checklist, follow-up actions.
struct AgentDetailCard: View {

    var task: AgentTask
    var floatTime: Double = 0.0
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider().opacity(0.12)
            subtaskList
            Divider().opacity(0.12)
            followUpActions
        }
        .frame(width: 300)
        .background(Color(hex: "#0E0E12").opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Header

    private var cardHeader: some View {
        HStack(spacing: 8) {
            // Morphing agent color dot
            MorphingDroplet(time: floatTime)
                .fill(task.color)
                .frame(width: 8, height: 8)
                .shadow(color: task.color.opacity(0.55), radius: 5)

            Text(task.title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
                .lineLimit(1)

            Spacer()

            // Status badge
            HStack(spacing: 4) {
                if task.overallStatus == .running {
                    Circle()
                        .fill(task.statusBadgeColor)
                        .frame(width: 4, height: 4)
                }
                Text(task.statusBadgeText)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(task.statusBadgeColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(task.statusBadgeColor.opacity(0.15))
            )

            // Dismiss button
            Button {
                withAnimation {
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.30))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Subtask List

    private var subtaskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if task.subtasks.isEmpty {
                Text("No subtasks defined")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.28))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ForEach(task.subtasks) { subtask in
                    subtaskRow(subtask)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subtaskRow(_ subtask: AgentSubtask) -> some View {
        HStack(spacing: 10) {
            // Status icon — animated for inProgress
            Image(systemName: subtask.statusIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(subtask.statusIconColor)
                .frame(width: 14, height: 14)

            Text(subtask.title)
                .font(.system(size: 10.5, weight: subtask.status == .done ? .regular : .medium))
                .foregroundColor(subtask.status == .done ? .white.opacity(0.35) : .white.opacity(0.72))
                .strikethrough(subtask.status == .done, color: .white.opacity(0.25))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            subtask.status == .inProgress
                ? Color(hex: "#FBBF24").opacity(0.04)
                : Color.clear
        )
    }

    // MARK: Follow-Up Actions

    private var followUpActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Follow up with agent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .padding(.horizontal, 14)
                .padding(.top, 10)

            HStack(spacing: 8) {
                // Text follow-up
                followUpButton(
                    icon: "character.cursor.ibeam",
                    label: "Text",
                    action: { /* Future: open text input to send message to agent */ }
                )
                // Voice follow-up
                followUpButton(
                    icon: "mic.fill",
                    label: "Voice",
                    action: { /* Future: trigger push-to-talk targeting this agent */ }
                )

                Spacer()

                // Dismiss agent (remove from active list)
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        isPresented = false
                        Task { @MainActor in
                            AgentManager.shared.removeTask(id: task.id)
                            KivoSoundFeedback.playOrbTap()
                        }
                    }
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.30))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.white.opacity(0.09), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func followUpButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - OrbPoppingParticles

private struct OrbPoppingParticles: View {
    let color: Color
    @State private var particleScale: CGFloat = 1.0
    @State private var particleOffsets: [CGSize] = Array(repeating: .zero, count: 8)
    @State private var particleOpacity: Double = 1.0

    var body: some View {
        ZStack {
            ForEach(0..<8) { i in
                Circle()
                    .fill(color)
                    .frame(width: 3, height: 3)
                    .offset(particleOffsets[i])
                    .opacity(particleOpacity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                particleOpacity = 0.0
                for i in 0..<8 {
                    let angle = Double(i) * (.pi / 4)
                    let distance: CGFloat = CGFloat.random(in: 12...24)
                    particleOffsets[i] = CGSize(
                        width: cos(angle) * distance,
                        height: sin(angle) * distance
                    )
                }
            }
        }
    }
}

// MARK: - MorphingDroplet

private struct MorphingDroplet: Shape {
    var time: Double

    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2

        // Calculate dynamic radius offsets for 4 cardinal directions (top, right, bottom, left)
        let rTop    = baseRadius * (1.0 + 0.18 * sin(time * 2.0))
        let rRight  = baseRadius * (1.0 + 0.18 * cos(time * 1.7 + 1.0))
        let rBottom = baseRadius * (1.0 + 0.18 * sin(time * 1.5 + 2.0))
        let rLeft   = baseRadius * (1.0 + 0.18 * cos(time * 2.2 + 3.0))

        var path = Path()

        // Cardinal points
        let pTop    = CGPoint(x: center.x, y: center.y - rTop)
        let pRight  = CGPoint(x: center.x + rRight, y: center.y)
        let pBottom = CGPoint(x: center.x, y: center.y + rBottom)
        let pLeft   = CGPoint(x: center.x - rLeft, y: center.y)

        // Control point offsets for smooth circle-like curves
        let handleTop    = rTop * 0.552
        let handleRight  = rRight * 0.552
        let handleBottom = rBottom * 0.552
        let handleLeft   = rLeft * 0.552

        path.move(to: pTop)

        // Top to Right curve
        path.addCurve(
            to: pRight,
            control1: CGPoint(x: pTop.x + handleTop, y: pTop.y),
            control2: CGPoint(x: pRight.x, y: pRight.y - handleRight)
        )

        // Right to Bottom curve
        path.addCurve(
            to: pBottom,
            control1: CGPoint(x: pRight.x, y: pRight.y + handleRight),
            control2: CGPoint(x: pBottom.x + handleBottom, y: pBottom.y)
        )

        // Bottom to Left curve
        path.addCurve(
            to: pLeft,
            control1: CGPoint(x: pBottom.x - handleBottom, y: pBottom.y),
            control2: CGPoint(x: pLeft.x, y: pLeft.y + handleLeft)
        )

        // Left to Top curve
        path.addCurve(
            to: pTop,
            control1: CGPoint(x: pLeft.x, y: pLeft.y - handleLeft),
            control2: CGPoint(x: pTop.x - handleTop, y: pTop.y)
        )

        path.closeSubpath()
        return path
    }
}
