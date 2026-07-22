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
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "PreCompact",
        "PostCompact",
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
            let hooks = try waitForCompleteHookSet()

            let trustEntries = Dictionary(uniqueKeysWithValues: hooks.map { hook in
                (hook.key, ["trusted_hash": hook.currentHash, "enabled": true] as [String: Any])
            })
            try writeTrustEntries(trustEntries)

            try waitForTrustedHookSet()
        }.value
    }

    static func repairInstalledHooksIfNeeded() async throws -> Bool {
        guard isInstalled else { return false }
        if !definitionsNeedUpdate, await resolvedStatus() == .active {
            return false
        }
        try await installAndTrust()
        return true
    }

    private static func install() throws {
        let fileManager = FileManager.default
        let codexHome = codexHomeURL(fileManager: fileManager)
        let binDirectory = codexHome.appending(path: "bin", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        guard let source = bundledHelperURL else {
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
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configuredHooks = root["hooks"] as? [String: Any]
        else { return false }
        return configuredHooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains(where: containsCodexMonitorHandler)
        }
    }

    private static var definitionsNeedUpdate: Bool {
        let fileManager = FileManager.default
        let codexHome = codexHomeURL(fileManager: fileManager)
        let hooksURL = codexHome.appending(path: "hooks.json")
        guard let data = try? Data(contentsOf: hooksURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return true }

        let installedEvents = Set(hooks.compactMap { event, value -> String? in
            guard let groups = value as? [[String: Any]],
                  groups.contains(where: containsCodexMonitorHandler)
            else { return nil }
            return event
        })
        guard Set(events).isSubset(of: installedEvents),
              Set(obsoleteEvents).isDisjoint(with: installedEvents)
        else { return true }

        guard let source = bundledHelperURL else { return false }
        let destination = codexHome.appending(path: "bin/\(helperName)")
        return !fileManager.contentsEqual(atPath: source.path, andPath: destination.path)
    }

    private static var bundledHelperURL: URL? {
        if let bundled = Bundle.main.url(forResource: "CodexMonitorHook", withExtension: nil) {
            return bundled
        }
        guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }
        let sibling = executableDirectory.appending(path: "CodexMonitorHook")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
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
            if ["PreToolUse", "PostToolUse", "PermissionRequest", "SubagentStart", "SubagentStop"].contains(event) {
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
                      let eventName = hook["eventName"] as? String,
                      let command = hook["command"] as? String,
                      command.contains(marker),
                      let currentHash = hook["currentHash"] as? String,
                      let trustStatus = hook["trustStatus"] as? String,
                      let enabled = hook["enabled"] as? Bool
                else { return nil }
                return DiscoveredHook(
                    key: key,
                    eventName: eventName,
                    currentHash: currentHash,
                    trustStatus: trustStatus,
                    enabled: enabled
                )
            }
    }

    private static func waitForCompleteHookSet() throws -> [DiscoveredHook] {
        for attempt in 0..<12 {
            let hooks = try monitorHooks()
            if Set(hooks.map(\.eventName)) == expectedEventNames {
                return hooks
            }
            if attempt < 11 { usleep(150_000) }
        }
        throw InstallError.hooksNotDiscovered
    }

    private static func waitForTrustedHookSet() throws {
        for attempt in 0..<12 {
            let hooks = try monitorHooks()
            if Set(hooks.map(\.eventName)) == expectedEventNames,
               hooks.allSatisfy({ $0.trustStatus == "trusted" && $0.enabled }) {
                return
            }
            if attempt < 11 { usleep(150_000) }
        }
        throw InstallError.trustWasNotSaved
    }

    private static var expectedEventNames: Set<String> {
        Set(events.map { event in
            event.prefix(1).lowercased() + event.dropFirst()
        })
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
            try? output.fileHandleForReading.close()
            stop(process)
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0,
              fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0
        else { throw InstallError.appServerUnavailable }

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
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, min(250, Int32(deadline.timeIntervalSinceNow * 1_000)))
            let pollResult = poll(&pollDescriptor, 1, remaining)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw InstallError.appServerUnavailable
            }
            if pollResult == 0 { continue }

            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                pending.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw InstallError.appServerUnavailable
            }

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

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
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
        let eventName: String
        let currentHash: String
        let trustStatus: String
        let enabled: Bool
    }
}
