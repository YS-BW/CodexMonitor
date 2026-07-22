import Foundation
import OSLog

struct CodexUsageFetcher: Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let logger = Logger(subsystem: "com.ysbw.CodexMonitor", category: "Quota")

    func fetch() async throws -> UsageSnapshot {
        var directError: Error?
        do {
            let snapshot = try await fetchDirectly()
            guard snapshot.statusWindow != nil else { throw UsageError.unavailable }
            return snapshot
        } catch {
            directError = error
            Self.logger.notice("Direct quota read failed; trying Codex app-server: \(error.localizedDescription, privacy: .public)")
        }

        do {
            return try await CodexAppServerUsageFetcher().fetch()
        } catch {
            Self.logger.error("Codex app-server quota read failed: \(error.localizedDescription, privacy: .public)")
            throw UsageError.allSourcesFailed(
                direct: directError?.localizedDescription ?? "unknown",
                appServer: error.localizedDescription
            )
        }
    }

    private func fetchDirectly() async throws -> UsageSnapshot {
        var credentials = try CodexOAuthCredentialsStore.load()
        if credentials.needsRefresh {
            do {
                credentials = try await refreshAndPersist(credentials)
            } catch {
                // A refresh timestamp is only a hint. The existing access token
                // can still be valid, so try it before falling back to RPC.
                Self.logger.notice("Proactive Codex token refresh failed; trying current token: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            return try await fetchDirectly(credentials: credentials)
        } catch UsageError.unauthorized {
            credentials = try await refreshAndPersist(credentials)
            return try await fetchDirectly(credentials: credentials)
        }
    }

    private func fetchDirectly(credentials: CodexOAuthCredentials) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.unavailable
        }
        if [401, 403].contains(httpResponse.statusCode) { throw UsageError.unauthorized }
        guard (200..<300).contains(httpResponse.statusCode) else { throw UsageError.unavailable }

        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        let windows = [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow].compactMap { $0 }
        let current = windows.first(where: { $0.limitWindowSeconds < 6 * 24 * 60 * 60 }).map(makeCurrentWindow)
        let weekly = windows.first(where: { $0.limitWindowSeconds >= 6 * 24 * 60 * 60 }).map(makeWeeklyWindow)
        return UsageSnapshot(current: current, weekly: weekly)
    }

    private func refreshAndPersist(_ credentials: CodexOAuthCredentials) async throws -> CodexOAuthCredentials {
        let refreshed = try await CodexOAuthTokenRefresher.refresh(credentials)
        do {
            try CodexOAuthCredentialsStore.save(refreshed)
        } catch {
            Self.logger.error("Refreshed Codex token but could not persist it: \(error.localizedDescription, privacy: .public)")
        }
        return refreshed
    }

    private func makeCurrentWindow(_ window: RateWindow) -> UsageWindow {
        UsageWindow(title: "5h 额度", remainingPercent: window.remainingPercent, resetsAt: window.resetDate)
    }

    private func makeWeeklyWindow(_ window: RateWindow) -> UsageWindow {
        UsageWindow(title: "本周额度", remainingPercent: window.remainingPercent, resetsAt: window.resetDate)
    }
}

private extension CodexUsageFetcher {
    struct UsageResponse: Decodable {
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: RateWindow?
        let secondaryWindow: RateWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct RateWindow: Decodable {
        let usedPercent: Double
        let resetAt: TimeInterval
        let limitWindowSeconds: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        var remainingPercent: Int { Int((100 - usedPercent).rounded()).clamped(to: 0...100) }
        var resetDate: Date { Date(timeIntervalSince1970: resetAt) }
    }

    enum UsageError: LocalizedError {
        case unavailable
        case unauthorized
        case allSourcesFailed(direct: String, appServer: String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "额度服务暂时不可用"
            case .unauthorized: "Codex 登录已过期"
            case .allSourcesFailed(let direct, let appServer):
                "额度读取失败（直连：\(direct)；本地接口：\(appServer)）"
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
