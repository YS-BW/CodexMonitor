import Darwin
import Foundation

enum CodexHookSetupStatus: Sendable, Equatable {
    case notInstalled
    case awaitingTrust
    case active

    var title: String {
        switch self {
        case .notInstalled: "Hooks · 启用"
        case .awaitingTrust: "Hooks · 待信任"
        case .active: "Hooks · 已启用"
        }
    }

    var isInstalled: Bool {
        self != .notInstalled
    }

    var isActive: Bool {
        self == .active
    }
}

enum CodexHookInstaller {
    private static let helperName = "codex-monitor-hook"
    private static let marker = "/.codex/bin/\(helperName)"
    private static let events = [
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "Stop",
        "SubagentStart",
        "SubagentStop",
    ]
    private static let obsoleteEvents = ["SessionEnd"]

    static var localStatus: CodexHookSetupStatus {
        isInstalled ? .awaitingTrust : .notInstalled
    }

    static func resolvedStatus() async -> CodexHookSetupStatus {
        guard isInstalled else { return .notInstalled }
        return await Task.detached(priority: .utility) {
            do {
                let hooks = try monitorHooks()
                return hooks.isEmpty || hooks.contains(where: {
                    $0.trustStatus != "trusted" || !$0.enabled
                })
                    ? .awaitingTrust
                    : .active
            } catch {
                return .awaitingTrust
            }
        }.value
    }

    static func installAndTrust() async throws {
        try await Task.detached(priority: .userInitiated) {
            try install()
            let hooks = try monitorHooks()
            guard !hooks.isEmpty else { throw InstallError.hooksNotDiscovered }

            let trustEntries = Dictionary(uniqueKeysWithValues: hooks.map { hook in
                (hook.key, ["trusted_hash": hook.currentHash, "enabled": true] as [String: Any])
            })
            try writeTrustEntries(trustEntries)

            let verifiedHooks = try monitorHooks()
            guard !verifiedHooks.isEmpty,
                  verifiedHooks.allSatisfy({ $0.trustStatus == "trusted" && $0.enabled })
            else { throw InstallError.trustWasNotSaved }
        }.value
    }

    private static func install() throws {
        let fileManager = FileManager.default
        let codexHome = codexHomeURL(fileManager: fileManager)
        let binDirectory = codexHome.appending(path: "bin", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        guard let source = Bundle.main.url(forResource: "CodexMonitorHook", withExtension: nil) else {
            throw InstallError.missingBundledHelper
        }
        let destination = binDirectory.appending(path: helperName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        guard chmod(destination.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            throw InstallError.cannotMakeExecutable
        }

        try mergeHooksJSON(at: codexHome.appending(path: "hooks.json"))
    }

    private static var isInstalled: Bool {
        let fileManager = FileManager.default
        let codexHome = codexHomeURL(fileManager: fileManager)
        let helper = codexHome.appending(path: "bin/\(helperName)")
        let hooks = codexHome.appending(path: "hooks.json")
        guard fileManager.isExecutableFile(atPath: helper.path),
              let data = try? Data(contentsOf: hooks),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.contains(marker)
    }

    private static func mergeHooksJSON(at url: URL) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.invalidExistingHooks
            }
            root = existing
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events + obsoleteEvents {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll(where: containsCodexMonitorHandler)
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []

            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "$HOME/.codex/bin/\(helperName) \(event)",
                    "timeout": 2,
                ]],
            ]
            if ["PreToolUse", "PermissionRequest", "SubagentStart", "SubagentStop"].contains(event) {
                group["matcher"] = ".*"
            }
            groups.append(group)
            hooks[event] = groups
        }

        root["hooks"] = hooks
        if root["description"] == nil {
            root["description"] = "Local lifecycle hooks, including Codex Monitor task animation."
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func monitorHooks() throws -> [DiscoveredHook] {
        let result = try runAppServerRequest(
            method: "hooks/list",
            params: ["cwds": [FileManager.default.homeDirectoryForCurrentUser.path]]
        )
        guard let entries = result["data"] as? [[String: Any]] else {
            throw InstallError.invalidAppServerResponse
        }

        return entries
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { hook -> DiscoveredHook? in
                guard let key = hook["key"] as? String,
                      let command = hook["command"] as? String,
                      command.contains(marker),
                      let currentHash = hook["currentHash"] as? String,
                      let trustStatus = hook["trustStatus"] as? String,
                      let enabled = hook["enabled"] as? Bool
                else { return nil }
                return DiscoveredHook(
                    key: key,
                    currentHash: currentHash,
                    trustStatus: trustStatus,
                    enabled: enabled
                )
            }
    }

    private static func writeTrustEntries(_ entries: [String: [String: Any]]) throws {
        _ = try runAppServerRequest(
            method: "config/batchWrite",
            params: [
                "edits": [[
                    "keyPath": "hooks.state",
                    "value": entries,
                    "mergeStrategy": "upsert",
                ]],
                "filePath": NSNull(),
                "expectedVersion": NSNull(),
                "reloadUserConfig": true,
            ]
        )
    }

    private static func runAppServerRequest(
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let process = Process()
        process.executableURL = try codexExecutableURL()
        process.arguments = ["app-server"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "codex-monitor", "version": "1"],
                ],
            ],
            ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
            ["jsonrpc": "2.0", "id": 2, "method": method, "params": params],
        ]
        for message in messages {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        var pending = Data()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let pollResult = poll(&pollDescriptor, 1, remaining)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw InstallError.appServerUnavailable
            }
            if pollResult == 0 { break }

            guard let chunk = try output.fileHandleForReading.read(upToCount: 65_536),
                  !chunk.isEmpty
            else { break }
            pending.append(chunk)

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == 2
                else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw InstallError.appServerError(error["message"] as? String ?? "Unknown error")
                }
                guard let result = object["result"] as? [String: Any] else {
                    throw InstallError.invalidAppServerResponse
                }
                return result
            }
        }
        throw InstallError.appServerTimedOut
    }

    private static func codexExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appending(path: "Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appending(path: "Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") }

        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else { throw InstallError.codexNotFound }
        return executable
    }

    private static func containsCodexMonitorHandler(_ group: [String: Any]) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains { handler in
            (handler["command"] as? String)?.contains(marker) == true
        }
    }

    private static func codexHomeURL(fileManager: FileManager) -> URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
    }

    enum InstallError: Error {
        case missingBundledHelper
        case cannotMakeExecutable
        case invalidExistingHooks
        case codexNotFound
        case hooksNotDiscovered
        case trustWasNotSaved
        case appServerUnavailable
        case appServerTimedOut
        case invalidAppServerResponse
        case appServerError(String)
    }

    private struct DiscoveredHook {
        let key: String
        let currentHash: String
        let trustStatus: String
        let enabled: Bool
    }
}
