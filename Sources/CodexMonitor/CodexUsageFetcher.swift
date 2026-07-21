import Foundation

struct CodexUsageFetcher: Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch() async throws -> UsageSnapshot {
        do {
            let snapshot = try await fetchDirectly()
            guard snapshot.statusWindow != nil else { throw UsageError.unavailable }
            return snapshot
        } catch {
            return try await CodexAppServerUsageFetcher().fetch()
        }
    }

    private func fetchDirectly() async throws -> UsageSnapshot {
        let credentials = try loadCredentials()
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UsageError.unavailable
        }

        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        let windows = [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow].compactMap { $0 }
        let current = windows.first(where: { $0.limitWindowSeconds < 6 * 24 * 60 * 60 }).map(makeCurrentWindow)
        let weekly = windows.first(where: { $0.limitWindowSeconds >= 6 * 24 * 60 * 60 }).map(makeWeeklyWindow)
        return UsageSnapshot(current: current, weekly: weekly)
    }

    private func loadCredentials() throws -> Credentials {
        let authURL = codexHomeURL().appending(path: "auth.json")
        let data = try Data(contentsOf: authURL)
        let auth = try JSONDecoder().decode(AuthFile.self, from: data)
        guard let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty else {
            throw UsageError.notSignedIn
        }
        return Credentials(accessToken: accessToken, accountID: auth.tokens?.accountID)
    }

    private func codexHomeURL() -> URL {
        if let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredHome.isEmpty
        {
            return URL(fileURLWithPath: configuredHome, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
    }

    private func makeCurrentWindow(_ window: RateWindow) -> UsageWindow {
        UsageWindow(title: "5h 额度", remainingPercent: window.remainingPercent, resetsAt: window.resetDate)
    }

    private func makeWeeklyWindow(_ window: RateWindow) -> UsageWindow {
        UsageWindow(title: "本周额度", remainingPercent: window.remainingPercent, resetsAt: window.resetDate)
    }
}

private extension CodexUsageFetcher {
    struct Credentials: Sendable {
        let accessToken: String
        let accountID: String?
    }

    struct AuthFile: Decodable {
        let tokens: Tokens?

        struct Tokens: Decodable {
            let accessToken: String?
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountID = "account_id"
            }
        }
    }

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

    enum UsageError: Error {
        case notSignedIn
        case unavailable
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
