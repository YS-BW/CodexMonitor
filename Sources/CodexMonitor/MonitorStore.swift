import Foundation
import Observation

@MainActor
@Observable
final class MonitorStore {
    private(set) var snapshot = UsageSnapshot.empty
    private(set) var sessions: [CodexSession] = []
    private(set) var isRefreshing = false
    private(set) var sessionReadError: String?
    private(set) var quotaReadError: String?
    var moduleOrder: [DashboardModule] = [.currentUsage, .weeklyUsage, .recentSessions]

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let sessionResult = CodexSessionScanner().recentSessions()
        async let usageResult = CodexUsageFetcher().fetch()

        do {
            sessions = try await sessionResult
            sessionReadError = nil
        } catch {
            sessionReadError = "未能读取本地会话"
        }

        do {
            snapshot = try await usageResult
            quotaReadError = nil
        } catch {
            quotaReadError = "未能读取额度"
        }
    }

}
