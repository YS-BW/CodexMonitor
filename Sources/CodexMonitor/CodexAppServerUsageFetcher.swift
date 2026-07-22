import AppKit
import Darwin
import Foundation

/// Asks the installed Codex binary for rate limits when credentials are stored
/// in Keychain, missing from auth.json, or no longer usable by the direct path.
struct CodexAppServerUsageFetcher: Sendable {
    func fetch() async throws -> UsageSnapshot {
        let installedApplications = await MainActor.run {
            ["com.openai.chat", "com.openai.codex"].compactMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }
        }
        guard let binaryURL = CodexBinaryLocator.resolve(applicationURLs: installedApplications) else {
            throw FetchError.codexNotInstalled
        }

        return try await Task.detached(priority: .utility) {
            try Self.fetchSynchronously(binaryURL: binaryURL)
        }.value
    }

    private static func fetchSynchronously(binaryURL: URL) throws -> UsageSnapshot {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw FetchError.launchFailed
        }

        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
        }

        let descriptor = outputPipe.fileHandleForReading.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0,
              fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0
        else {
            throw FetchError.readFailed
        }

        var pendingData = Data()
        try send(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-monitor",
                        "version": Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "dev",
                    ],
                ],
            ],
            to: inputPipe.fileHandleForWriting
        )
        _ = try waitForResult(
            id: 1,
            timeout: 8,
            descriptor: descriptor,
            process: process,
            pendingData: &pendingData
        )
        try send(
            ["method": "initialized", "params": [:]],
            to: inputPipe.fileHandleForWriting
        )
        try send(
            ["id": 2, "method": "account/rateLimits/read", "params": [:]],
            to: inputPipe.fileHandleForWriting
        )

        let result = try waitForResult(
            id: 2,
            timeout: 5,
            descriptor: descriptor,
            process: process,
            pendingData: &pendingData
        )
        let resultData = try JSONSerialization.data(withJSONObject: result)
        let response = try JSONDecoder().decode(ResultPayload.self, from: resultData)
        return makeSnapshot(from: response.rateLimits)
    }

    private static func waitForResult(
        id: Int,
        timeout: TimeInterval,
        descriptor: Int32,
        process: Process,
        pendingData: inout Data
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }

            if let result = try decodeAvailableLines(id: id, from: &pendingData) {
                return result
            }

            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remainingMilliseconds = max(1, min(250, Int32(deadline.timeIntervalSinceNow * 1_000)))
            let pollResult = poll(&pollDescriptor, 1, remainingMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw FetchError.readFailed
            }
            if pollResult == 0 { continue }

            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                pendingData.append(contentsOf: bytes.prefix(count))
                continue
            }
            if count == 0 {
                throw FetchError.processExited
            }
            if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                throw FetchError.readFailed
            }
        }

        throw FetchError.timedOut(method: id == 1 ? "initialize" : "account/rateLimits/read")
    }

    private static func send(_ payload: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    static func decodeAvailableLines(id: Int, from data: inout Data) throws -> [String: Any]? {
        while let newline = data.firstIndex(of: 0x0A) {
            let line = Data(data[..<newline])
            data.removeSubrange(...newline)
            guard !line.isEmpty else { continue }

            guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (response["id"] as? NSNumber)?.intValue == id
            else { continue }
            if let error = response["error"] as? [String: Any] {
                throw FetchError.serverError(
                    error["message"] as? String ?? "Codex app-server returned an error"
                )
            }
            guard let result = response["result"] as? [String: Any] else {
                throw FetchError.invalidResponse
            }
            return result
        }
        return nil
    }

    private static func makeSnapshot(from limits: RateLimits) -> UsageSnapshot {
        let windows = [limits.primary, limits.secondary].compactMap { $0 }
        let current = windows.first { $0.windowDurationMins < 6 * 24 * 60 }?
            .usageWindow(title: "5h 额度")
        let weekly = windows.first { $0.windowDurationMins >= 6 * 24 * 60 }?
            .usageWindow(title: "本周额度")
        return UsageSnapshot(current: current, weekly: weekly)
    }
}

private extension CodexAppServerUsageFetcher {
    struct ResultPayload: Decodable {
        let rateLimits: RateLimits
    }

    struct RateLimits: Decodable {
        let primary: RateWindow?
        let secondary: RateWindow?
    }

    struct RateWindow: Decodable {
        let usedPercent: Double
        let windowDurationMins: Double
        let resetsAt: TimeInterval?

        func usageWindow(title: String) -> UsageWindow? {
            guard let resetsAt else { return nil }
            let remaining = Int((100 - usedPercent).rounded()).clamped(to: 0...100)
            return UsageWindow(
                title: title,
                remainingPercent: remaining,
                resetsAt: Date(timeIntervalSince1970: resetsAt)
            )
        }
    }

    enum FetchError: LocalizedError {
        case codexNotInstalled
        case launchFailed
        case processExited
        case readFailed
        case invalidResponse
        case timedOut(method: String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .codexNotInstalled: "没有找到 Codex Desktop 或 Codex CLI"
            case .launchFailed: "无法启动 Codex 本地服务"
            case .processExited: "Codex 本地服务提前退出"
            case .readFailed: "无法读取 Codex 本地服务响应"
            case .invalidResponse: "Codex 本地服务返回了无效数据"
            case .timedOut(let method): "Codex 本地服务请求超时（\(method)）"
            case .serverError(let message): "Codex 本地服务错误：\(message)"
            }
        }
    }
}

enum CodexBinaryLocator {
    static func resolve(
        applicationURLs: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [URL]()

        if let override = environment["CODEX_BINARY"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        candidates.append(contentsOf: applicationURLs.map {
            $0.appending(path: "Contents/Resources/codex")
        })

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appending(path: "Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appending(path: "Applications/Codex.app/Contents/Resources/codex"),
            home.appending(path: ".local/bin/codex"),
            home.appending(path: ".volta/bin/codex"),
            home.appending(path: ".asdf/shims/codex"),
            home.appending(path: ".local/share/mise/shims/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ])

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appending(path: "codex")
            })
        }

        let nodeVersions = home.appending(path: ".nvm/versions/node", directoryHint: .isDirectory)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nodeVersions,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            candidates.append(contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appending(path: "bin/codex") })
        }

        var seen = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return fileManager.isExecutableFile(atPath: path)
        }?.standardizedFileURL
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
