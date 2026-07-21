import Foundation
import SwiftUI

/// A task, owned either by the user or delegated to the agent.
struct TodoItem: Identifiable, Codable, Equatable {
    enum Owner: String, Codable, CaseIterable {
        case me, athena
        var label: String { self == .me ? "You" : "Athena" }
        var icon: String { self == .me ? "person.fill" : "sparkles" }
        var tint: Color { self == .me ? Theme.blue : Theme.amber }
    }

    /// Agent-reported state. Completion itself is always the user's call.
    enum Status: String, Codable {
        case open, working, waitingOnUser, readyForReview

        var label: String {
            switch self {
            case .open: "Not started"
            case .working: "Athena working"
            case .waitingOnUser: "Needs you"
            case .readyForReview: "Ready for review"
            }
        }
        var tint: Color {
            switch self {
            case .open: Theme.textFaint
            case .working: Theme.amber
            case .waitingOnUser: Theme.red
            case .readyForReview: Theme.green
            }
        }
    }

    var id: String = UUID().uuidString
    var title: String
    var notes: String = ""
    var owner: Owner = .me
    var status: Status = .open
    var done: Bool = false
    var percent: Int? = nil
    var progress: [ProgressNote] = []
    var questions: [AgentQuestion] = []
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var dueAt: Date? = nil

    var openQuestions: [AgentQuestion] { questions.filter { $0.answer == nil } }
    var needsAttention: Bool { !openQuestions.isEmpty || status == .waitingOnUser }
}

struct ProgressNote: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var at: Date = .now
    var percent: Int? = nil
}

struct AgentQuestion: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var at: Date = .now
    var answer: String? = nil
    var answeredAt: Date? = nil
}

/// One line the agent appends to its update log.
struct TodoLogEntry: Codable {
    var type: String        // "progress" | "question" | "status"
    var todoId: String
    var text: String?
    var percent: Int?
    var status: String?
    var at: String?         // ISO8601
}
