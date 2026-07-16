import Foundation

struct CodexSessionScanner: Sendable {
    func recentSessions(limit: Int = 3, now: Date = .now) async throws -> [CodexSession] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let root = URL(fileURLWithPath: home, isDirectory: true).appending(path: "sessions", directoryHint: .isDirectory)
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let dates = (0...7).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }
        let fileManager = FileManager.default

        var results: [CodexSession] = []
        for date in dates {
            let folder = root.appending(path: formatter.string(from: date), directoryHint: .isDirectory)
            guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                guard let modifiedAt = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      let metadata = readMetadata(from: file) else { continue }
                let project = metadata.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名项目"
                results.append(CodexSession(
                    id: metadata.id,
                    title: readFirstUserMessage(from: file) ?? project,
                    preview: readLastUserMessage(from: file) ?? "暂无可显示的对话内容",
                    source: metadata.source,
                    lastActivityAt: modifiedAt,
                    isActive: now.timeIntervalSince(modifiedAt) < 120
                ))
            }
        }
        let titles = CodexThreadTitleReader().titles(for: results.map(\.id))
        var seen = Set<String>()
        return results
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { session in
                CodexSession(
                    id: session.id,
                    title: titles[session.id] ?? session.title,
                    preview: session.preview,
                    source: session.source,
                    lastActivityAt: session.lastActivityAt,
                    isActive: session.isActive
                )
            }
    }

    private func readMetadata(from file: URL) -> (id: String, cwd: String?, source: CodexSession.Source)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let lineData = data.split(separator: 0x0A, maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = (payload["session_id"] as? String) ?? (payload["id"] as? String) else { return nil }
        let origin = [payload["originator"], payload["source"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
        let source: CodexSession.Source
        if origin.contains("desktop") || origin.contains("app-server") { source = .desktopApp }
        else if origin.contains("ide") || origin.contains("vscode") || origin.contains("cursor") || origin.contains("zed") { source = .ide }
        else if origin.contains("cli") || origin.contains("exec") { source = .cli }
        else { source = .unknown }
        return (id, payload["cwd"] as? String, source)
    }

    private func readLastUserMessage(from file: URL) -> String? {
        readUserMessage(from: file, preferLast: true)
    }

    private func readFirstUserMessage(from file: URL) -> String? {
        readUserMessage(from: file, preferLast: false)
    }

    private func readUserMessage(from file: URL, preferLast: Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = preferLast && size > 512 * 1024 ? size - 512 * 1024 : 0
        try? handle.seek(toOffset: start)
        guard let data = preferLast ? (try? handle.readToEnd()) : (try? handle.read(upToCount: 512 * 1024)),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let orderedLines = preferLast ? Array(lines.reversed()) : lines
        for line in orderedLines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(String(line).utf8)) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]] else { continue }

            let message: String = content
                .filter { ($0["type"] as? String) == "input_text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            guard !message.isEmpty,
                  !message.hasPrefix("<") else { continue }
            return message
                .replacingOccurrences(of: "\\s+", with: " ", options: String.CompareOptions.regularExpression)
                .prefix(90)
                .description
        }
        return nil
    }
}
