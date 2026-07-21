import Darwin
import Foundation

/// Asks the installed Codex binary for rate limits when credentials are stored
/// in Keychain, missing from auth.json, or no longer usable by the direct path.
struct CodexAppServerUsageFetcher: Sendable {
    func fetch() async throws -> UsageSnapshot {
        guard let binaryURL = CodexBinaryLocator.resolve() else {
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
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
            }
        }

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
        try send(
            ["method": "initialized", "params": [:]],
            to: inputPipe.fileHandleForWriting
        )
        try send(
            ["id": 2, "method": "account/rateLimits/read", "params": [:]],
            to: inputPipe.fileHandleForWriting
        )

        let descriptor = outputPipe.fileHandleForReading.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0,
              fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0
        else {
            throw FetchError.readFailed
        }

        var pendingData = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }

            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                pendingData.append(contentsOf: bytes.prefix(count))
                if let snapshot = try decodeAvailableLines(from: &pendingData) {
                    return snapshot
                }
                continue
            }
            if count == 0, !process.isRunning {
                throw FetchError.processExited
            }
            if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                throw FetchError.readFailed
            }
            Thread.sleep(forTimeInterval: 0.025)
        }

        throw FetchError.timedOut
    }

    private static func send(_ payload: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func decodeAvailableLines(from data: inout Data) throws -> UsageSnapshot? {
        while let newline = data.firstIndex(of: 0x0A) {
            let line = Data(data[..<newline])
            data.removeSubrange(...newline)
            guard !line.isEmpty else { continue }

            let response: RPCResponse
            do {
                response = try JSONDecoder().decode(RPCResponse.self, from: line)
            } catch {
                continue
            }
            guard response.id == 2 else { continue }
            guard let limits = response.result?.rateLimits else {
                throw FetchError.invalidResponse
            }
            return makeSnapshot(from: limits)
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
    struct RPCResponse: Decodable {
        let id: Int?
        let result: ResultPayload?
    }

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

    enum FetchError: Error {
        case codexNotInstalled
        case launchFailed
        case processExited
        case readFailed
        case invalidResponse
        case timedOut
    }
}

private enum CodexBinaryLocator {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [URL]()

        if let override = environment["CODEX_BINARY"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

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
