//
//  AgentTask.swift
//  leanring-buddy
//
//  Data model + shared store for all running Kivo agents.
//
//  Uses the modern @Observable macro (macOS 14+) instead of ObservableObject.
//  @Observable works cleanly with @MainActor without Swift 6 conformance issues:
//  the macro synthesises tracking infrastructure that is MainActor-compatible
//  by design, whereas ObservableObject's objectWillChange publisher must be
//  accessible from nonisolated contexts — which conflicts with @MainActor class
//  isolation in Swift 6 strict mode.
//
//  Usage:
//    AgentManager.shared.addTask(title: "Build site", subtasks: [...])
//    AgentManager.shared.updateSubtask(agentId: id, subtaskId: sid, status: .done)
//    AgentManager.shared.finishTask(id: id, outcome: .done)
//

import Foundation
import Observation
import SwiftUI

// MARK: - Subtask Status

enum AgentSubtaskStatus: String {
    case pending    // Not started yet — shown as ⏳
    case inProgress // Currently running — shown as 🔄
    case done       // Finished — shown as ✅
    case failed     // Error — shown as ❌
}

// MARK: - Agent Overall Status

enum AgentOverallStatus: String {
    case running
    case done
    case failed
}

// MARK: - AgentSubtask

struct AgentSubtask: Identifiable, Equatable {
    let id: UUID
    var title: String
    var status: AgentSubtaskStatus

    init(id: UUID = UUID(), title: String, status: AgentSubtaskStatus = .pending) {
        self.id = id
        self.title = title
        self.status = status
    }

    // SF Symbol name for the subtask status — used in cards and detail popovers
    var statusIcon: String {
        switch status {
        case .pending:    return "clock"
        case .inProgress: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .done:       return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        }
    }

    var statusIconColor: Color {
        switch status {
        case .pending:    return Color.white.opacity(0.28)
        case .inProgress: return Color(hex: "#FBBF24") // Amber
        case .done:       return Color(hex: "#22C55E") // Green
        case .failed:     return Color(hex: "#EF4444") // Red
        }
    }
}

// MARK: - AgentTask

/// Represents a single running agent task. @Observable enables SwiftUI to
/// automatically track property access and update views when properties change.
@Observable
final class AgentTask: Identifiable, Equatable {
    let id: UUID
    let title: String

    /// Unique accent color for this agent — auto-assigned from the rotating palette
    let color: Color

    var overallStatus: AgentOverallStatus
    var subtasks: [AgentSubtask]

    let startedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        color: Color,
        overallStatus: AgentOverallStatus = .running,
        subtasks: [AgentSubtask] = [],
        startedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.overallStatus = overallStatus
        self.subtasks = subtasks
        self.startedAt = startedAt
    }

    static func == (lhs: AgentTask, rhs: AgentTask) -> Bool {
        lhs.id == rhs.id
    }

    // Fraction of subtasks that are done — drives the compact progress bar
    var completionFraction: Double {
        guard !subtasks.isEmpty else { return 0 }
        let doneCount = subtasks.filter { $0.status == .done }.count
        return Double(doneCount) / Double(subtasks.count)
    }

    var statusBadgeText: String {
        switch overallStatus {
        case .running: return "Running"
        case .done:    return "Done"
        case .failed:  return "Failed"
        }
    }

    var statusBadgeColor: Color {
        switch overallStatus {
        case .running: return Color(hex: "#FBBF24") // Amber
        case .done:    return Color(hex: "#22C55E") // Green
        case .failed:  return Color(hex: "#EF4444") // Red
        }
    }
}

// MARK: - AgentManager

/// Singleton store for all active Kivo agents.
/// @Observable + @MainActor is the correct macOS 14+ pattern — unlike
/// ObservableObject, the @Observable macro's tracking infrastructure is
/// fully compatible with MainActor isolation in Swift 6 strict mode.
@MainActor
@Observable
final class AgentManager {

    static let shared = AgentManager()

    // No @Published needed — @Observable tracks this automatically
    private(set) var activeTasks: [AgentTask] = []

    // Rotating color palette — each new agent gets the next color in the cycle
    private static let agentColorPalette: [Color] = [
        Color(hex: "#22C55E"), // Green
        Color(hex: "#EC4899"), // Pink / Rose
        Color(hex: "#3B82F6"), // Blue
        Color(hex: "#F59E0B"), // Amber
        Color(hex: "#8B5CF6"), // Violet
        Color(hex: "#06B6D4"), // Cyan
        Color(hex: "#F97316"), // Orange
        Color(hex: "#A78BFA"), // Purple-ish
    ]

    private var nextColorIndex: Int = 0

    private init() {}

    // MARK: - Add Task

    /// Creates a new agent task and appends it to the active list.
    /// Returns the created task so callers can capture the ID for future updates.
    @discardableResult
    func addTask(title: String, subtasks: [String]) -> AgentTask {
        let assignedColor = Self.agentColorPalette[nextColorIndex % Self.agentColorPalette.count]
        nextColorIndex += 1

        let agentSubtasks = subtasks.map { AgentSubtask(title: $0) }
        let newTask = AgentTask(
            title: title,
            color: assignedColor,
            overallStatus: .running,
            subtasks: agentSubtasks
        )
        activeTasks.append(newTask)
        return newTask
    }

    // MARK: - Update Subtask

    /// Marks a specific subtask within an agent as a new status.
    func updateSubtask(agentId: UUID, subtaskId: UUID, newStatus: AgentSubtaskStatus) {
        guard let taskIndex = activeTasks.firstIndex(where: { $0.id == agentId }) else { return }
        guard let subtaskIndex = activeTasks[taskIndex].subtasks.firstIndex(where: { $0.id == subtaskId }) else { return }
        activeTasks[taskIndex].subtasks[subtaskIndex].status = newStatus
    }

    // MARK: - Finish Task

    /// Updates the overall status of an agent (e.g. to .done or .failed).
    /// Also marks all remaining pending/inProgress subtasks as done when outcome is .done.
    func finishTask(id: UUID, outcome: AgentOverallStatus) {
        guard let task = activeTasks.first(where: { $0.id == id }) else { return }
        task.overallStatus = outcome

        if outcome == .done {
            for index in task.subtasks.indices {
                if task.subtasks[index].status != .done {
                    task.subtasks[index].status = .done
                }
            }
        }
    }

    // MARK: - Remove Task

    /// Removes a task from the active list (e.g. user dismissed it).
    func removeTask(id: UUID) {
        activeTasks.removeAll { $0.id == id }
    }

    // MARK: - Demo Helper

    /// Adds a realistic-looking demo agent so the UI can be tested without a real backend.
    /// Called by the debug "+" button in the Agents tab.
    @discardableResult
    func addDemoTask() -> AgentTask {
        let demoTitles = [
            "Build Hello World Site",
            "Create React Dashboard",
            "Write Unit Tests",
            "Deploy to Vercel",
            "Refactor Auth Module",
        ]
        let demoSubtasks = [
            ["Scaffold project structure", "Write index.html", "Add CSS styling", "Deploy to Vercel", "Send confirmation"],
            ["Init Vite + React", "Create components", "Wire up routing", "Fetch API data", "Write README"],
            ["Identify test cases", "Write test stubs", "Implement assertions", "Run test suite"],
            ["Build production bundle", "Configure domain", "Upload assets", "Verify deployment"],
            ["Audit existing code", "Extract helper functions", "Write new tests", "Open pull request"],
        ]
        let randomIndex = Int.random(in: 0..<demoTitles.count)
        return addTask(title: demoTitles[randomIndex], subtasks: demoSubtasks[randomIndex])
    }
}
