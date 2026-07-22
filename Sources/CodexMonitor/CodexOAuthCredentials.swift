import Darwin
import Foundation

struct CodexOAuthCredentials: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountID: String?
    let lastRefresh: Date?

    var needsRefresh: Bool {
        if accessTokenExpiresSoon { return true }
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }

    private var accessTokenExpiresSoon: Bool {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3,
              let payload = Self.decodeBase64URL(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let expiration = (object["exp"] as? NSNumber)?.doubleValue
        else { return false }
        return expiration < Date().addingTimeInterval(5 * 60).timeIntervalSince1970
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

enum CodexOAuthCredentialsStore {
    static func load(from url: URL = authURL()) throws -> CodexOAuthCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> CodexOAuthCredentials {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = string(in: tokens, snake: "access_token", camel: "accessToken"),
              !accessToken.isEmpty
        else { throw StoreError.missingTokens }

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: string(in: tokens, snake: "refresh_token", camel: "refreshToken"),
            idToken: string(in: tokens, snake: "id_token", camel: "idToken"),
            accountID: string(in: tokens, snake: "account_id", camel: "accountId"),
            lastRefresh: parseDate(root["last_refresh"])
        )
    }

    static func save(_ credentials: CodexOAuthCredentials, to url: URL = authURL()) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = existing
        }

        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = credentials.accessToken
        if let refreshToken = credentials.refreshToken { tokens["refresh_token"] = refreshToken }
        if let idToken = credentials.idToken { tokens["id_token"] = idToken }
        if let accountID = credentials.accountID { tokens["account_id"] = accountID }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: .now)

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw StoreError.cannotSecureFile
        }
    }

    static func authURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true).appending(path: "auth.json")
        }
        return fileManager.homeDirectoryForCurrentUser
            .appending(path: ".codex/auth.json")
    }

    private static func string(in object: [String: Any], snake: String, camel: String) -> String? {
        (object[snake] as? String) ?? (object[camel] as? String)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    enum StoreError: LocalizedError {
        case notFound
        case missingTokens
        case cannotSecureFile

        var errorDescription: String? {
            switch self {
            case .notFound: "没有找到 Codex 登录凭据"
            case .missingTokens: "Codex 登录凭据不完整"
            case .cannotSecureFile: "无法安全保存 Codex 登录凭据"
            }
        }
    }
}

enum CodexOAuthTokenRefresher {
    private static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func refresh(
        _ credentials: CodexOAuthCredentials,
        session: URLSession = .shared
    ) async throws -> CodexOAuthCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw RefreshError.missingRefreshToken
        }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RefreshError.invalidResponse }
        guard http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty
        else { throw RefreshError.rejected(statusCode: http.statusCode) }

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String ?? refreshToken,
            idToken: object["id_token"] as? String ?? credentials.idToken,
            accountID: credentials.accountID,
            lastRefresh: .now
        )
    }

    enum RefreshError: LocalizedError {
        case missingRefreshToken
        case invalidResponse
        case rejected(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .missingRefreshToken: "Codex 登录凭据缺少刷新令牌"
            case .invalidResponse: "Codex 登录服务返回了无效响应"
            case .rejected(let statusCode): "Codex 登录刷新失败（HTTP \(statusCode)）"
            }
        }
    }
}
