import Foundation
import Observation

@MainActor
@Observable
final class MonitorStore {
    private(set) var snapshot = UsageSnapshot.empty
    private(set) var sessions: [CodexSession] = []
    private(set) var tokenSummary = TokenSummary.empty
    private(set) var tokenTrend = TokenTrend.empty
    private(set) var tokenPeriods = TokenPeriodSummary.empty
    private(set) var taskProgresses: [CodexTaskProgress] = []
    private(set) var isRefreshing = false
    private(set) var sessionReadError: String?
    private(set) var quotaReadError: String?
    var moduleOrder: [DashboardModule] = [
        .taskProgress, .currentUsage, .weeklyUsage, .totalTokens,
        .dailyTokens, .weeklyTokens, .monthlyTokens,
        .tokenTrend, .recentSessions
    ]
    private var autoRefreshTask: Task<Void, Never>?
    private var tokenRefreshTask: Task<Void, Never>?
    private var refreshIntervalMinutes: Int?
    private let progressScanner = CodexTaskProgressScanner()
    private let sessionEventMonitor = CodexSessionEventMonitor()
    private static let snapshotCacheKey = "cachedUsageSnapshot"

    init() {
        snapshot = Self.loadCachedSnapshot() ?? .empty
        Task { await refresh() }
        startProgressMonitoring()
        let storedInterval = UserDefaults.standard.object(forKey: "refreshIntervalMinutes") as? Int ?? 5
        setRefreshInterval(storedInterval)
    }

    private func startProgressMonitoring() {
        sessionEventMonitor.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshTaskProgress()
            }
        }
        sessionEventMonitor.start()
        Task { await refreshTaskProgress() }
    }

    private func refreshTaskProgress() async {
        let progresses = await progressScanner.latestTasks()
        if taskProgresses != progresses {
            taskProgresses = progresses
        }
    }

    func setRefreshInterval(_ minutes: Int) {
        let normalized = [0, 1, 5, 15, 30].contains(minutes) ? minutes : 5
        guard normalized != refreshIntervalMinutes else { return }
        refreshIntervalMinutes = normalized
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard normalized > 0 else { return }

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(normalized * 60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let sessionResult = CodexSessionScanner().recentSessions()
        async let usageResult = CodexUsageFetcher().fetch()
        startTokenUsageRefresh()

        do {
            snapshot = try await usageResult
            Self.saveCachedSnapshot(snapshot)
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

    }

    private func startTokenUsageRefresh() {
        guard tokenRefreshTask == nil else { return }
        tokenRefreshTask = Task { [weak self] in
            let tokenUsage: TokenUsageReport = await Task.detached(priority: .utility) {
                CodexThreadTitleReader().tokenUsageReport()
            }.value
            guard !Task.isCancelled, let self else { return }
            tokenSummary = tokenUsage.summary
            tokenPeriods = tokenUsage.periods
            tokenTrend = tokenUsage.trend
            tokenRefreshTask = nil
        }
    }

    private static func loadCachedSnapshot() -> UsageSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotCacheKey) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    private static func saveCachedSnapshot(_ snapshot: UsageSnapshot) {
        guard snapshot.statusWindow != nil,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: snapshotCacheKey)
    }

}
