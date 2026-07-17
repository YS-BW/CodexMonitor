import Foundation
import Observation

@MainActor
@Observable
final class MonitorStore {
    private(set) var snapshot = UsageSnapshot.empty
    private(set) var sessions: [CodexSession] = []
    private(set) var tokenSummary = TokenSummary.empty
    private(set) var tokenTrend = TokenTrend.empty
    private(set) var isRefreshing = false
    private(set) var sessionReadError: String?
    private(set) var quotaReadError: String?
    var moduleOrder: [DashboardModule] = [.currentUsage, .weeklyUsage, .totalTokens, .tokenTrend, .recentSessions]

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let sessionResult = CodexSessionScanner().recentSessions()
        async let usageResult = CodexUsageFetcher().fetch()
        async let tokenResult: TokenSummary = Task.detached(priority: .userInitiated) {
            CodexThreadTitleReader().totalTokens()
        }.value
        async let trendResult: TokenTrend = Task.detached(priority: .utility) {
            CodexThreadTitleReader().recentTokenTrend()
        }.value

        // Keep the menu-bar value responsive: the SQLite summary is quick,
        // while parsing historical JSONL for the chart is deliberately low priority.
        tokenSummary = await tokenResult

        do {
            snapshot = try await usageResult
            quotaReadError = nil
        } catch {
            quotaReadError = "未能读取额度"
        }

        do {
            sessions = try await sessionResult
            sessionReadError = nil
        } catch {
            sessionReadError = "未能读取本地会话"
        }

        tokenTrend = await trendResult
    }

}
