import Foundation
import Observation
import CodexMonitorHookSupport

@MainActor
@Observable
final class MonitorStore {
    private(set) var snapshot = UsageSnapshot.empty
    private(set) var sessions: [CodexSession] = []
    private(set) var tokenSummary = TokenSummary.empty
    private(set) var tokenTrend = TokenTrend.empty
    private(set) var tokenPeriods = TokenPeriodSummary.empty
    private(set) var hookSnapshot = CodexHookSnapshot()
    private(set) var hookSetupStatus: CodexHookSetupStatus = .notInstalled
    private(set) var isRefreshing = false
    private(set) var sessionReadError: String?
    private(set) var quotaReadError: String?
    var moduleOrder: [DashboardModule] {
        didSet { Self.saveModuleOrder(moduleOrder) }
    }
    private static let defaultModuleOrder: [DashboardModule] = [
        .currentUsage, .weeklyUsage, .totalTokens,
        .dailyTokens, .weeklyTokens, .monthlyTokens,
        .tokenTrend, .recentSessions
    ]
    private var autoRefreshTask: Task<Void, Never>?
    private var tokenRefreshTask: Task<Void, Never>?
    private var dogStateRefreshTask: Task<Void, Never>?
    private var dogStateRevision = 0
    private var refreshIntervalMinutes: Int?
    private let hookStateMonitor = CodexHookStateMonitor()
    private static let snapshotCacheKey = "cachedUsageSnapshot"
    private static let moduleOrderKey = "dashboardModuleOrder"

    init() {
        moduleOrder = Self.loadModuleOrder()
        snapshot = Self.loadCachedSnapshot() ?? .empty
        startHookMonitoring()
        Task { await refresh() }
        let storedInterval = UserDefaults.standard.object(forKey: "refreshIntervalMinutes") as? Int ?? 1
        setRefreshInterval(storedInterval)
        Task { await repairInstalledHooksIfNeeded() }
    }

    private func startHookMonitoring() {
        hookSnapshot = CodexHookStateStore.read()
        hookSetupStatus = CodexHookInstaller.localStatus
        hookStateMonitor.onChange = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.hookSnapshot = snapshot
                self?.scheduleDogStateRefresh(for: snapshot)
            }
        }
        hookStateMonitor.start()
        scheduleDogStateRefresh(for: hookSnapshot)
    }

    var dogActivityState: DogActivityState {
        _ = dogStateRevision
        return switch hookSnapshot.effectiveStatus {
        case .thinking: .thinking
        case .working: .working
        case .waiting: .waiting
        case nil: .idle
        }
    }

    private func scheduleDogStateRefresh(for snapshot: CodexHookSnapshot) {
        dogStateRefreshTask?.cancel()
        dogStateRefreshTask = nil
        guard !snapshot.tasks.isEmpty, let lastPromptAt = snapshot.lastPromptAt else { return }

        let deadline = lastPromptAt.addingTimeInterval(
            CodexHookSnapshot.minimumThinkingDisplayDuration
        )
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return }

        dogStateRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            dogStateRevision += 1
            dogStateRefreshTask = nil
        }
    }

    func installCodexHooks() async throws {
        hookSetupStatus = .awaitingTrust
        do {
            try await CodexHookInstaller.installAndTrust()
            hookSetupStatus = .active
        } catch {
            hookSetupStatus = CodexHookInstaller.localStatus
            throw error
        }
    }

    func reloadHookSetupStatus() async {
        hookSetupStatus = await CodexHookInstaller.resolvedStatus()
    }

    private func repairInstalledHooksIfNeeded() async {
        do {
            _ = try await CodexHookInstaller.repairInstalledHooksIfNeeded()
            hookSetupStatus = await CodexHookInstaller.resolvedStatus()
        } catch {
            hookSetupStatus = CodexHookInstaller.localStatus
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
            quotaReadError = error.localizedDescription
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

    private static func loadModuleOrder() -> [DashboardModule] {
        guard let rawOrder = UserDefaults.standard.stringArray(forKey: moduleOrderKey) else {
            return defaultModuleOrder
        }

        let savedModules = rawOrder.compactMap(DashboardModule.init(rawValue:))
        let missingModules = defaultModuleOrder.filter { !savedModules.contains($0) }
        let completeOrder = savedModules + missingModules
        return completeOrder.isEmpty ? defaultModuleOrder : completeOrder
    }

    private static func saveModuleOrder(_ order: [DashboardModule]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: moduleOrderKey)
    }

}
