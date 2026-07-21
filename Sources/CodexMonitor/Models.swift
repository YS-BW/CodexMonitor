import Foundation

struct UsageWindow: Sendable, Codable {
    let title: String
    let remainingPercent: Int
    let resetsAt: Date
}

struct UsageSnapshot: Sendable, Codable {
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
    let source: Source
    let tokensUsed: Int
    let goalStatus: GoalStatus?
    let lastActivityAt: Date
    let isActive: Bool

    enum GoalStatus: Sendable {
        case inProgress
        case completed
        case unknown

        init(rawValue: String) {
            switch rawValue.lowercased() {
            case "active", "in_progress", "in-progress", "running":
                self = .inProgress
            case "complete", "completed", "done", "success":
                self = .completed
            default:
                self = .unknown
            }
        }

        var label: String {
            switch self {
            case .inProgress: "Goal：进行中"
            case .completed: "Goal：完成"
            case .unknown: "Goal"
            }
        }
    }
}

struct TokenSummary: Sendable {
    let totalTokens: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let eventCount: Int

    init(
        totalTokens: Int,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        eventCount: Int = 0
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.eventCount = eventCount
    }

    static let empty = TokenSummary(totalTokens: 0)
}

struct TokenTrend: Sendable {
    struct Day: Identifiable, Sendable {
        let date: Date
        let tokens: Int

        var id: Date { date }
    }

    let days: [Day]

    static let empty = TokenTrend(days: [])
}

struct TokenPeriodSummary: Sendable {
    let todayTokens: Int
    let weekTokens: Int
    let monthTokens: Int

    static let empty = TokenPeriodSummary(todayTokens: 0, weekTokens: 0, monthTokens: 0)
}

struct TokenUsageReport: Sendable {
    let summary: TokenSummary
    let trend: TokenTrend
    let periods: TokenPeriodSummary

    static let empty = TokenUsageReport(summary: .empty, trend: .empty, periods: .empty)
}

struct CodexTaskProgress: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case thinking
        case running
        case waitingForApproval
        case waitingForInput
        case completed
        case failed
        case aborted
        case stalled
    }

    struct PlanStep: Sendable, Equatable {
        enum Status: String, Sendable {
            case pending
            case inProgress
            case completed
        }

        let title: String
        let status: Status
    }

    let sessionID: String
    let source: CodexSession.Source
    let title: String
    let phase: String
    let state: State
    let startedAt: Date
    let lastActivityAt: Date
    let completedAt: Date?
    let operationCount: Int
    let plan: [PlanStep]
    let goalStatus: CodexSession.GoalStatus?

    var completedPlanSteps: Int {
        plan.count { $0.status == .completed }
    }
}

enum DashboardModule: String, CaseIterable, Identifiable, Sendable {
    case taskProgress
    case currentUsage
    case weeklyUsage
    case totalTokens
    case dailyTokens
    case weeklyTokens
    case monthlyTokens
    case tokenTrend
    case recentSessions

    var id: String { rawValue }
}

enum CLITerminal: String, CaseIterable, Sendable {
    case terminal
    case ghostty

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .ghostty: "Ghostty"
        }
    }
}
