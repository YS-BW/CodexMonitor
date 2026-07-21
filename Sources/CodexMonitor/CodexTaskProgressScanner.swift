import Foundation
import SQLite3

/// Reads Codex's append-only local rollout logs without sending any model request.
/// Active files are parsed once and then incrementally as new JSONL records arrive.
actor CodexTaskProgressScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var remainder = Data()
        var sessionID: String?
        var source: CodexSession.Source = .unknown
        var task: MutableTask?
    }

    private struct MutableTask {
        var title = ""
        var phase = "正在准备任务"
        var state: CodexTaskProgress.State = .thinking
        var startedAt: Date
        var lastActivityAt: Date
        var completedAt: Date?
        var operationCount = 0
        var plan: [CodexTaskProgress.PlanStep] = []
        var waitingCallID: String?
    }

    private var states: [URL: FileState] = [:]
    private var metadataCache: [String: CodexThreadTitleReader.Metadata] = [:]
    private var metadataSignature = ""
    private let fileManager = FileManager.default
    private let dateParser = ISO8601DateFormatter()

    func latestTasks(now: Date = .now, limit: Int = 3) -> [CodexTaskProgress] {
        let candidates = recentRolloutFiles(now: now)
        for file in candidates {
            update(file)
        }

        let snapshots = candidates.compactMap { snapshot(for: $0, now: now) }
        let active = snapshots
            .filter { ![.completed, .failed, .aborted].contains($0.state) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        let recentTerminal = snapshots
            .filter { [.completed, .failed, .aborted].contains($0.state) }
            .filter { now.timeIntervalSince($0.completedAt ?? $0.lastActivityAt) < 15 * 60 }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }

        return (active + recentTerminal)
            .prefix(max(1, limit))
            .map(enrich)
    }

    private func recentRolloutFiles(now: Date) -> [URL] {
        let databaseURL = codexHome.appending(path: "state_5.sqlite")
        var database: OpaquePointer?
        if sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
           let database {
            defer { sqlite3_close(database) }
            let cutoff = Int64(now.timeIntervalSince1970) - 24 * 60 * 60
            let sql = "SELECT rollout_path FROM threads WHERE updated_at >= ? ORDER BY updated_at DESC LIMIT 4"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
               let statement {
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, cutoff)
                var paths: [URL] = []
                while sqlite3_step(statement) == SQLITE_ROW,
                      let path = sqlite3_column_text(statement, 0) {
                    let url = URL(fileURLWithPath: String(cString: path))
                    if fileManager.fileExists(atPath: url.path) { paths.append(url) }
                }
                if !paths.isEmpty { return paths }
            }
        }

        // Older Codex builds may not maintain state_5.sqlite. Keep a filesystem
        // fallback so progress monitoring still works with those versions.
        let root = codexHome.appending(path: "sessions", directoryHint: .isDirectory)
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"

        var files: [(url: URL, modifiedAt: Date)] = []
        for offset in 0...7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let folder = root.appending(path: formatter.string(from: date), directoryHint: .isDirectory)
            guard let contents = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in contents where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                guard let modifiedAt = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modifiedAt) < 24 * 60 * 60
                else { continue }
                files.append((file, modifiedAt))
            }
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(4)
            .map(\.url)
    }

    private func update(_ file: URL) {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        let fileSize = UInt64(max(0, size))
        var state = states[file] ?? FileState()

        if state.sessionID == nil {
            readSessionMetadata(from: file, into: &state)
        }
        if fileSize < state.offset {
            state = FileState()
            readSessionMetadata(from: file, into: &state)
        }
        guard fileSize > state.offset else {
            states[file] = state
            return
        }

        if state.offset == 0 {
            readInitialTail(from: file, fileSize: fileSize, into: &state)
        } else {
            readAppendedData(from: file, fileSize: fileSize, into: &state)
        }
        states[file] = state
    }

    private func readInitialTail(from file: URL, fileSize: UInt64, into state: inout FileState) {
        let tailSize: UInt64 = 16 * 1_024 * 1_024
        parseRange(from: file, offset: fileSize > tailSize ? fileSize - tailSize : 0, fileSize: fileSize, into: &state)

        // A very output-heavy turn can exceed the tail window. Fall back to one
        // full background pass so running/completed state is never guessed.
        if state.task == nil, fileSize > tailSize {
            state.task = nil
            state.remainder = Data()
            parseRange(from: file, offset: 0, fileSize: fileSize, into: &state)
        }
    }

    private func readAppendedData(from file: URL, fileSize: UInt64, into state: inout FileState) {
        parseRange(from: file, offset: state.offset, fileSize: fileSize, into: &state)
    }

    private func parseRange(from file: URL, offset: UInt64, fileSize: UInt64, into state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let incoming = try handle.readToEnd() ?? Data()
            var data = state.remainder
            data.append(incoming)

            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if offset > 0, state.offset == 0, !data.starts(with: Data("{".utf8)) {
                if !lines.isEmpty { lines.removeFirst() }
            }
            if data.last != 0x0A {
                state.remainder = lines.popLast().map { Data($0) } ?? Data()
            } else {
                state.remainder = Data()
                if lines.last?.isEmpty == true { lines.removeLast() }
            }

            for line in lines where !line.isEmpty {
                consume(Data(line), state: &state)
            }
            state.offset = fileSize
        } catch {
            return
        }
    }

    private func consume(_ line: Data, state: inout FileState) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let timestamp = date(from: object["timestamp"]) ?? .now

        if object["type"] as? String == "session_meta",
           let payload = object["payload"] as? [String: Any] {
            applySessionMetadata(payload, to: &state)
            return
        }

        if let method = object["method"] as? String, method == "turn/plan/updated",
           var task = state.task {
            task.plan = parsePlan(from: object["params"]) ?? task.plan
            task.lastActivityAt = timestamp
            state.task = task
            return
        }

        guard let payload = object["payload"] as? [String: Any] else { return }
        let outerType = object["type"] as? String
        let type = payload["type"] as? String ?? ""

        if outerType == "event_msg" {
            consumeEvent(type: type, payload: payload, timestamp: timestamp, state: &state)
        } else if outerType == "response_item" {
            consumeItem(type: type, payload: payload, timestamp: timestamp, state: &state)
        }
    }

    private func consumeEvent(
        type: String,
        payload: [String: Any],
        timestamp: Date,
        state: inout FileState
    ) {
        switch type {
        case "task_started", "turn_started":
            let startedAt = date(from: payload["started_at"]) ?? timestamp
            state.task = MutableTask(startedAt: startedAt, lastActivityAt: timestamp)
        case "user_message":
            guard var task = state.task,
                  let message = CodexDisplayText.userRequest(from: payload["message"] as? String)
            else { return }
            task.title = message
            task.lastActivityAt = timestamp
            state.task = task
        case "agent_message":
            guard var task = state.task else { return }
            let phase = payload["phase"] as? String
            if phase == "commentary", let message = CodexDisplayText.summary(payload["message"] as? String) {
                task.phase = message
                task.state = .thinking
            } else if phase == "final_answer" {
                task.phase = "正在整理结果"
                task.state = .thinking
            }
            task.lastActivityAt = timestamp
            state.task = task
        case "task_complete", "turn_completed":
            guard var task = state.task else { return }
            task.state = .completed
            task.phase = ""
            task.completedAt = date(from: payload["completed_at"]) ?? timestamp
            task.lastActivityAt = timestamp
            state.task = task
        case "turn_aborted", "task_aborted":
            guard var task = state.task else { return }
            task.state = .aborted
            task.phase = "任务已中止"
            task.completedAt = timestamp
            task.lastActivityAt = timestamp
            state.task = task
        case "task_failed", "turn_failed":
            guard var task = state.task else { return }
            task.state = .failed
            task.phase = "任务执行失败"
            task.completedAt = timestamp
            task.lastActivityAt = timestamp
            state.task = task
        case "exec_approval_request", "apply_patch_approval_request":
            guard var task = state.task else { return }
            task.state = .waitingForApproval
            task.phase = "等待操作授权"
            task.lastActivityAt = timestamp
            state.task = task
        default:
            guard var task = state.task else { return }
            task.lastActivityAt = timestamp
            state.task = task
        }
    }

    private func consumeItem(
        type: String,
        payload: [String: Any],
        timestamp: Date,
        state: inout FileState
    ) {
        guard var task = state.task else { return }

        switch type {
        case "custom_tool_call", "function_call":
            let name = payload["name"] as? String ?? ""
            let input = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
            if let plan = parsePlanCall(name: name, input: input) {
                task.plan = plan
            }
            let inferred = inferTool(name: name, input: input)
            task.phase = inferred.phase
            task.state = inferred.state
            if inferred.state == .waitingForInput || inferred.state == .waitingForApproval {
                task.waitingCallID = payload["call_id"] as? String
            }
        case "custom_tool_call_output", "function_call_output":
            task.operationCount += 1
            let callID = payload["call_id"] as? String
            if task.waitingCallID == nil || task.waitingCallID == callID {
                if task.state == .waitingForInput || task.state == .waitingForApproval {
                    task.phase = "正在继续任务"
                    task.waitingCallID = nil
                }
            }
            task.state = .thinking
            task.phase = "正在思考下一步"
        case "reasoning":
            task.state = .thinking
            task.phase = "正在思考"
        case "message":
            if payload["role"] as? String == "user",
               let content = payload["content"] as? [[String: Any]],
               let message = CodexDisplayText.userRequest(
                   from: content
                       .filter { ($0["type"] as? String) == "input_text" }
                       .compactMap { $0["text"] as? String }
               ) {
                task.title = message
            }
        default:
            break
        }

        task.lastActivityAt = timestamp
        state.task = task
    }

    private func inferTool(name: String, input: String) -> (phase: String, state: CodexTaskProgress.State) {
        let haystack = (name + " " + input).lowercased()
        if name == "request_user_input" || haystack.contains("tools.request_user_input(") {
            return ("等待你的回答", .waitingForInput)
        }
        if name.lowercased().contains("approval") || haystack.contains("tools.request_approval(") {
            return ("等待操作授权", .waitingForApproval)
        }
        if haystack.contains("apply_patch") || haystack.contains("file_change") {
            return ("正在修改代码", .running)
        }
        if haystack.contains("web__run") || haystack.contains("search_query") || haystack.contains("web_search") {
            return ("正在搜索资料", .running)
        }
        if haystack.contains("swift build") || haystack.contains("xcodebuild") || haystack.contains(" build") {
            return ("正在构建项目", .running)
        }
        if haystack.contains("swift test") || haystack.contains(" test") || haystack.contains("pytest") {
            return ("正在运行测试", .running)
        }
        if haystack.contains("view_image") || haystack.contains("screenshot") {
            return ("正在检查界面", .running)
        }
        if haystack.contains("read") || haystack.contains("sed -n") || haystack.contains("rg ") {
            return ("正在分析项目文件", .running)
        }
        return ("正在执行操作", .running)
    }

    private func parsePlanCall(name: String, input: String) -> [CodexTaskProgress.PlanStep]? {
        if name == "update_plan", let data = input.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return parsePlan(from: object)
        }
        guard input.contains("update_plan") else { return nil }

        let pattern = #"\{\s*"?step"?\s*:\s*"((?:\\.|[^"])*)"\s*,\s*"?status"?\s*:\s*"(pending|in_progress|inProgress|completed)"\s*\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        let steps = expression.matches(in: input, range: range).compactMap { match -> CodexTaskProgress.PlanStep? in
            guard let titleRange = Range(match.range(at: 1), in: input),
                  let statusRange = Range(match.range(at: 2), in: input),
                  let status = planStatus(String(input[statusRange])) else { return nil }
            let rawTitle = String(input[titleRange])
            let title = decodeJSONString(rawTitle)
            return CodexTaskProgress.PlanStep(title: title, status: status)
        }
        return steps.isEmpty ? nil : steps
    }

    private func parsePlan(from value: Any?) -> [CodexTaskProgress.PlanStep]? {
        guard let object = value as? [String: Any] else { return nil }
        let candidates = (object["plan"] as? [[String: Any]])
            ?? (object["steps"] as? [[String: Any]])
            ?? ((object["params"] as? [String: Any])?["plan"] as? [[String: Any]])
        guard let candidates else { return nil }
        let steps = candidates.compactMap { item -> CodexTaskProgress.PlanStep? in
            guard let title = (item["step"] as? String) ?? (item["title"] as? String),
                  let rawStatus = item["status"] as? String,
                  let status = planStatus(rawStatus) else { return nil }
            return CodexTaskProgress.PlanStep(title: title, status: status)
        }
        return steps.isEmpty ? nil : steps
    }

    private func planStatus(_ value: String) -> CodexTaskProgress.PlanStep.Status? {
        switch value {
        case "pending": .pending
        case "in_progress", "inProgress": .inProgress
        case "completed": .completed
        default: nil
        }
    }

    private func snapshot(for file: URL, now: Date) -> CodexTaskProgress? {
        guard let state = states[file], let sessionID = state.sessionID, let task = state.task else { return nil }
        var displayState = task.state
        var phase = task.phase
        if (task.state == .running || task.state == .thinking),
           now.timeIntervalSince(task.lastActivityAt) > 10 * 60 {
            displayState = .stalled
            phase = "较长时间没有新活动"
        }
        return CodexTaskProgress(
            sessionID: sessionID,
            source: state.source,
            title: task.title,
            phase: phase,
            state: displayState,
            startedAt: task.startedAt,
            lastActivityAt: task.lastActivityAt,
            completedAt: task.completedAt,
            operationCount: task.operationCount,
            plan: task.plan,
            goalStatus: nil
        )
    }

    private func enrich(_ progress: CodexTaskProgress) -> CodexTaskProgress {
        let signature = enrichmentSignature
        if signature != metadataSignature {
            metadataSignature = signature
            metadataCache.removeAll(keepingCapacity: true)
        }
        if metadataCache[progress.sessionID] == nil,
           let metadata = CodexThreadTitleReader().metadata(for: [progress.sessionID])[progress.sessionID] {
            metadataCache[progress.sessionID] = metadata
        }
        let metadata = metadataCache[progress.sessionID]
        let title = CodexDisplayText.summary(metadata?.title)
            ?? CodexDisplayText.userRequest(from: progress.title)
            ?? "未命名会话"
        return CodexTaskProgress(
            sessionID: progress.sessionID,
            source: progress.source,
            title: title,
            phase: progress.phase,
            state: progress.state,
            startedAt: progress.startedAt,
            lastActivityAt: progress.lastActivityAt,
            completedAt: progress.completedAt,
            operationCount: progress.operationCount,
            plan: progress.plan,
            goalStatus: metadata?.goalStatus
        )
    }

    private func readSessionMetadata(from file: URL, into state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1_024),
              let line = data.split(separator: 0x0A, maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        applySessionMetadata(payload, to: &state)
    }

    private func applySessionMetadata(_ payload: [String: Any], to state: inout FileState) {
        state.sessionID = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? state.sessionID
        let origin = [payload["originator"], payload["source"]]
            .compactMap { $0 as? String }
            .joined(separator: " ")
            .lowercased()
        if origin.contains("desktop") || origin.contains("app-server") { state.source = .desktopApp }
        else if origin.contains("ide") || origin.contains("vscode") || origin.contains("cursor") || origin.contains("zed") { state.source = .ide }
        else if origin.contains("cli") || origin.contains("exec") { state.source = .cli }
    }

    private func date(from value: Any?) -> Date? {
        if let string = value as? String { return dateParser.date(from: string) }
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        return nil
    }

    private func decodeJSONString(_ value: String) -> String {
        let wrapped = "\"\(value)\""
        guard let data = wrapped.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? String else { return value }
        return decoded
    }

    private var codexHome: URL {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: ".codex").path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var enrichmentSignature: String {
        ["session_index.jsonl", "goals_1.sqlite"].map { name in
            let url = codexHome.appending(path: name)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(name):\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }
}
