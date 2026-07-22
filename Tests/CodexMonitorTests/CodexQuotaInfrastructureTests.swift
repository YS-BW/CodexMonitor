import Foundation
import XCTest
@testable import CodexMonitor

final class CodexQuotaInfrastructureTests: XCTestCase {
    func testLiveQuotaFetchWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEX_MONITOR_LIVE_TEST"] == "1")

        let snapshot = try await CodexUsageFetcher().fetch()

        XCTAssertNotNil(snapshot.statusWindow)
    }

    func testLiveAppServerFallbackWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEX_MONITOR_LIVE_TEST"] == "1")

        let snapshot = try await CodexAppServerUsageFetcher().fetch()

        XCTAssertNotNil(snapshot.statusWindow)
    }

    func testParsesSnakeCaseOAuthCredentials() throws {
        let data = Data(#"""
        {
          "tokens": {
            "access_token": "access",
            "refresh_token": "refresh",
            "id_token": "id",
            "account_id": "account"
          },
          "last_refresh": "2026-07-20T07:54:19.711718Z"
        }
        """#.utf8)

        let credentials = try CodexOAuthCredentialsStore.parse(data)

        XCTAssertEqual(credentials.accessToken, "access")
        XCTAssertEqual(credentials.refreshToken, "refresh")
        XCTAssertEqual(credentials.idToken, "id")
        XCTAssertEqual(credentials.accountID, "account")
        XCTAssertNotNil(credentials.lastRefresh)
    }

    func testParsesCamelCaseTokenFieldsFromNewerClients() throws {
        let data = Data(#"""
        {
          "tokens": {
            "accessToken": "access",
            "refreshToken": "refresh",
            "accountId": "account"
          }
        }
        """#.utf8)

        let credentials = try CodexOAuthCredentialsStore.parse(data)

        XCTAssertEqual(credentials.accessToken, "access")
        XCTAssertEqual(credentials.refreshToken, "refresh")
        XCTAssertEqual(credentials.accountID, "account")
    }

    func testExpiredJWTNeedsRefreshEvenWithRecentRefreshTimestamp() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "exp": Date().addingTimeInterval(-60).timeIntervalSince1970,
        ])
        let token = "header.\(base64URL(payload)).signature"
        let credentials = CodexOAuthCredentials(
            accessToken: token,
            refreshToken: "refresh",
            idToken: nil,
            accountID: nil,
            lastRefresh: .now
        )

        XCTAssertTrue(credentials.needsRefresh)
    }

    func testSavingCredentialsPreservesUnrelatedAuthFieldsAndSecuresFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appending(path: "auth.json")
        try Data(#"{"auth_mode":"chatgpt","custom":"keep"}"#.utf8).write(to: authURL)

        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                idToken: nil,
                accountID: "account",
                lastRefresh: .now
            ),
            to: authURL
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any]
        )
        XCTAssertEqual(object["auth_mode"] as? String, "chatgpt")
        XCTAssertEqual(object["custom"] as? String, "keep")
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["access_token"] as? String, "new-access")
        let permissions = try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testAppServerDecoderSkipsNotificationsAndWaitsForRequestedID() throws {
        var data = Data(#"""
{"method":"account/rateLimits/updated","params":{}}
{"id":1,"result":{"userAgent":"codex"}}
{"id":2,"result":{"rateLimits":{"primary":null,"secondary":null}}}
"""#.utf8)
        data.append(0x0A)

        let initialize = try CodexAppServerUsageFetcher.decodeAvailableLines(id: 1, from: &data)
        XCTAssertEqual(initialize?["userAgent"] as? String, "codex")
        let rateLimits = try CodexAppServerUsageFetcher.decodeAvailableLines(id: 2, from: &data)
        XCTAssertNotNil(rateLimits?["rateLimits"])
    }

    func testAppServerDecoderSurfacesRPCError() {
        var data = Data(#"""
{"id":2,"error":{"message":"login required"}}
"""#.utf8)
        data.append(0x0A)

        XCTAssertThrowsError(
            try CodexAppServerUsageFetcher.decodeAvailableLines(id: 2, from: &data)
        )
    }

    func testBinaryLocatorFindsCodexInsideDiscoveredApplication() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = directory.appending(path: "Moved Codex.app", directoryHint: .isDirectory)
        let executable = appURL.appending(path: "Contents/Resources/codex")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        XCTAssertEqual(chmod(executable.path, 0o700), 0)

        let resolved = CodexBinaryLocator.resolve(
            applicationURLs: [appURL],
            environment: [:],
            fileManager: .default
        )

        XCTAssertEqual(resolved, executable)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
