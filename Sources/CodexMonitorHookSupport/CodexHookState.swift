import Darwin
import Foundation

public enum CodexHookTaskStatus: String, Codable, Sendable {
    case thinking
    case working
    case waiting
}

public struct CodexHookTask: Codable, Sendable, Equatable {
    public let sessionID: String
    public let turnID: String
    public var status: CodexHookTaskStatus
    public var updatedAt: Date
    public var activeWorkIDs: Set<String>?
    public var transcriptPath: String?

    public init(
        sessionID: String,
        turnID: String,
        status: CodexHookTaskStatus,
        updatedAt: Date,
        activeWorkIDs: Set<String> = [],
        transcriptPath: String? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.status = status
        self.updatedAt = updatedAt
        self.activeWorkIDs = activeWorkIDs
        self.transcriptPath = transcriptPath
    }
}

public struct CodexHookSnapshot: Codable, Sendable, Equatable {
    public static let minimumThinkingDisplayDuration: TimeInterval = 1.1
    public static let staleTaskDuration: TimeInterval = 6 * 60 * 60
    public var version = 1
    public var updatedAt: Date
    public var lastEventName: String
    public var lastPromptAt: Date?
    public var tasks: [String: CodexHookTask]

    public init(
        updatedAt: Date = .distantPast,
        lastEventName: String = "",
        lastPromptAt: Date? = nil,
        tasks: [String: CodexHookTask] = [:]
    ) {
        self.updatedAt = updatedAt
        self.lastEventName = lastEventName
        self.lastPromptAt = lastPromptAt
        self.tasks = tasks
    }

    public var hasWorkingTask: Bool {
        liveTasks(at: .now).contains { $0.status == .working }
    }

    public var effectiveStatus: CodexHookTaskStatus? {
        effectiveStatus(at: .now)
    }

    public func effectiveStatus(at now: Date) -> CodexHookTaskStatus? {
        let liveTasks = liveTasks(at: now)
        if liveTasks.contains(where: { $0.status == .waiting }) { return .waiting }
        if !liveTasks.isEmpty,
           let lastPromptAt,
           now.timeIntervalSince(lastPromptAt) < Self.minimumThinkingDisplayDuration {
            return .thinking
        }
        if liveTasks.contains(where: { $0.status == .working }) { return .working }
        if liveTasks.contains(where: { $0.status == .thinking }) { return .thinking }
        return nil
    }

    public func nextTaskExpiration(after now: Date = .now) -> Date? {
        tasks.values
            .map { $0.updatedAt.addingTimeInterval(Self.staleTaskDuration) }
            .filter { $0 > now }
            .min()
    }

    public mutating func apply(_ event: CodexHookEvent, now: Date = .now) {
        pruneStaleTasks(now: now)
        updatedAt = now
        lastEventName = event.name

        let sessionID = event.sessionID ?? "unknown-session"
        let turnID = event.turnID ?? "unknown-turn"
        let key = Self.taskKey(sessionID: sessionID, turnID: turnID)

        switch event.name {
        case "SessionStart":
            tasks = tasks.filter { $0.value.sessionID != sessionID }
            if tasks.isEmpty { lastPromptAt = nil }
        case "UserPromptSubmit":
            lastPromptAt = now
            tasks = tasks.filter { $0.value.sessionID != sessionID }
            tasks[key] = CodexHookTask(
                sessionID: sessionID,
                turnID: turnID,
                status: .thinking,
                updatedAt: now,
                transcriptPath: event.transcriptPath
            )
        case "PreToolUse", "SubagentStart":
            var task = tasks[key] ?? CodexHookTask(
                sessionID: sessionID,
                turnID: turnID,
                status: .thinking,
                updatedAt: now,
                transcriptPath: event.transcriptPath
            )
            var activeWorkIDs = task.activeWorkIDs ?? []
            activeWorkIDs.insert(event.workID)
            task.activeWorkIDs = activeWorkIDs
            task.transcriptPath = event.transcriptPath ?? task.transcriptPath
            task.status = .working
            task.updatedAt = now
            tasks[key] = task
        case "PostToolUse", "SubagentStop":
            guard var task = tasks[key] else { break }
            var activeWorkIDs = task.activeWorkIDs ?? []
            activeWorkIDs.remove(event.workID)
            task.activeWorkIDs = activeWorkIDs
            task.transcriptPath = event.transcriptPath ?? task.transcriptPath
            task.status = activeWorkIDs.isEmpty ? .thinking : .working
            task.updatedAt = now
            tasks[key] = task
        case "PreCompact", "PostCompact":
            var task = tasks[key] ?? CodexHookTask(
                sessionID: sessionID,
                turnID: turnID,
                status: .thinking,
                updatedAt: now,
                transcriptPath: event.transcriptPath
            )
            task.transcriptPath = event.transcriptPath ?? task.transcriptPath
            task.status = .thinking
            task.updatedAt = now
            tasks[key] = task
        case "PermissionRequest":
            var task = tasks[key] ?? CodexHookTask(
                sessionID: sessionID,
                turnID: turnID,
                status: .thinking,
                updatedAt: now,
                transcriptPath: event.transcriptPath
            )
            task.transcriptPath = event.transcriptPath ?? task.transcriptPath
            task.status = .waiting
            task.updatedAt = now
            tasks[key] = task
        case "Stop":
            if !removeTask(sessionID: sessionID, turnID: turnID) {
                tasks = tasks.filter { $0.value.sessionID != sessionID }
                if tasks.isEmpty { lastPromptAt = nil }
            }
        case "SessionEnd":
            tasks = tasks.filter { $0.value.sessionID != sessionID }
            if tasks.isEmpty { lastPromptAt = nil }
        default:
            break
        }
    }

    @discardableResult
    public mutating func removeTask(sessionID: String, turnID: String) -> Bool {
        let removed = tasks.removeValue(forKey: Self.taskKey(sessionID: sessionID, turnID: turnID)) != nil
        if tasks.isEmpty { lastPromptAt = nil }
        return removed
    }

    public mutating func pruneStaleTasks(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.staleTaskDuration)
        tasks = tasks.filter { $0.value.updatedAt > cutoff }
        if tasks.isEmpty { lastPromptAt = nil }
    }

    private func liveTasks(at now: Date) -> [CodexHookTask] {
        let cutoff = now.addingTimeInterval(-Self.staleTaskDuration)
        return tasks.values.filter { $0.updatedAt > cutoff }
    }

    private static func taskKey(sessionID: String, turnID: String) -> String {
        "\(sessionID):\(turnID)"
    }
}

public struct CodexHookEvent: Codable, Sendable, Equatable {
    public let name: String
    public let sessionID: String?
    public let turnID: String?
    public let toolUseID: String?
    public let agentID: String?
    public let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case name = "hook_event_name"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case toolUseID = "tool_use_id"
        case agentID = "agent_id"
        case transcriptPath = "transcript_path"
    }

    public init(
        name: String,
        sessionID: String?,
        turnID: String?,
        toolUseID: String? = nil,
        agentID: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.name = name
        self.sessionID = sessionID
        self.turnID = turnID
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.transcriptPath = transcriptPath
    }

    var workID: String {
        if name == "SubagentStart" || name == "SubagentStop" {
            return "agent:\(agentID ?? "unknown")"
        }
        return "tool:\(toolUseID ?? "unknown")"
    }

    public static func decode(_ data: Data, fallbackName: String? = nil) -> CodexHookEvent {
        if var event = try? JSONDecoder().decode(CodexHookEvent.self, from: data) {
            if event.name.isEmpty, let fallbackName {
                event = CodexHookEvent(
                    name: fallbackName,
                    sessionID: event.sessionID,
                    turnID: event.turnID,
                    toolUseID: event.toolUseID,
                    agentID: event.agentID,
                    transcriptPath: event.transcriptPath
                )
            }
            return event
        }
        return CodexHookEvent(name: fallbackName ?? "", sessionID: nil, turnID: nil)
    }
}

public enum CodexHookStateStore {
    public static let statePathEnvironmentKey = "CODEX_MONITOR_HOOK_STATE_PATH"

    public static func stateURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[statePathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/CodexMonitor", directoryHint: .isDirectory)
            .appending(path: "hook-state.json")
    }

    public static func read(
        from url: URL = stateURL(),
        now: Date = .now
    ) -> CodexHookSnapshot {
        guard let data = try? Data(contentsOf: url) else { return CodexHookSnapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var snapshot = try? decoder.decode(CodexHookSnapshot.self, from: data) else {
            return CodexHookSnapshot()
        }
        snapshot.pruneStaleTasks(now: now)
        return snapshot
    }

    public static func apply(event: CodexHookEvent, to url: URL = stateURL()) throws {
        try update(url: url) { snapshot in
            snapshot.apply(event)
        }
    }

    @discardableResult
    public static func removeTask(
        sessionID: String,
        turnID: String,
        from url: URL = stateURL()
    ) throws -> Bool {
        var removed = false
        try update(url: url) { snapshot in
            removed = snapshot.removeTask(sessionID: sessionID, turnID: turnID)
        }
        return removed
    }

    private static func update(
        url: URL,
        mutation: (inout CodexHookSnapshot) -> Void
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.cannotOpenLock }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.cannotLock }
        defer { flock(descriptor, LOCK_UN) }

        var snapshot = read(from: url)
        mutation(&snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public enum StoreError: Error {
        case cannotOpenLock
        case cannotLock
    }
}
