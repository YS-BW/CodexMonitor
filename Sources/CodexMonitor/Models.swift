import Foundation

struct UsageWindow: Sendable {
    let title: String
    let remainingPercent: Int
    let resetsAt: Date
}

struct UsageSnapshot: Sendable {
    let current: UsageWindow?
    let weekly: UsageWindow?

    static let empty = UsageSnapshot(current: nil, weekly: nil)

    var statusWindow: UsageWindow? { current ?? weekly }
}

struct CodexSession: Identifiable, Sendable {
    enum Source: String, Sendable {
        case desktopApp = "Codex App"
        case cli = "CLI"
        case ide = "IDE"
        case unknown = "Codex"
    }

    let id: String
    let title: String
    let preview: String
    let source: Source
    let lastActivityAt: Date
    let isActive: Bool
}

enum DashboardModule: String, CaseIterable, Identifiable, Sendable {
    case currentUsage
    case weeklyUsage
    case recentSessions

    var id: String { rawValue }
}
