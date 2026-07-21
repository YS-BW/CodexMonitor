import Foundation
import SQLite3

struct CodexThreadTitleReader: Sendable {
    struct Metadata: Sendable {
        let title: String?
        let tokensUsed: Int
        let goalStatus: CodexSession.GoalStatus?
    }

    func metadata(for ids: [String]) -> [String: Metadata] {
        guard !ids.isEmpty else { return [:] }

        let databaseURL = codexHome.appending(path: "state_5.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return [:] }
        defer { sqlite3_close(database) }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT id, title, tokens_used FROM threads WHERE id IN (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, sqliteTransient)
        }

        var metadata: [String: Metadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW,
              let idPointer = sqlite3_column_text(statement, 0) {
            let id = String(cString: idPointer)
            let title = sqlite3_column_text(statement, 1).map {
                String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            metadata[id] = Metadata(
                title: title?.isEmpty == false ? title : nil,
                tokensUsed: Int(sqlite3_column_int64(statement, 2)),
                goalStatus: nil
            )
        }
        return attachSessionIndexTitles(to: attachGoalStatuses(to: metadata, ids: ids), ids: ids)
    }

    func tokenUsageReport(trendDays: Int = 7, now: Date = .now) -> TokenUsageReport {
        CodexTokenUsageScanner().report(trendDays: trendDays, now: now)
    }

    private func attachGoalStatuses(to metadata: [String: Metadata], ids: [String]) -> [String: Metadata] {
        let goalsURL = codexHome.appending(path: "goals_1.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(goalsURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return metadata }
        defer { sqlite3_close(database) }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT thread_id, status FROM thread_goals WHERE thread_id IN (\(placeholders)) ORDER BY updated_at_ms DESC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return metadata }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, sqliteTransient)
        }

        var result = metadata
        while sqlite3_step(statement) == SQLITE_ROW,
              let idPointer = sqlite3_column_text(statement, 0),
              let statusPointer = sqlite3_column_text(statement, 1) {
            let id = String(cString: idPointer)
            guard let item = result[id], item.goalStatus == nil else { continue }
            result[id] = Metadata(
                title: item.title,
                tokensUsed: item.tokensUsed,
                goalStatus: CodexSession.GoalStatus(rawValue: String(cString: statusPointer))
            )
        }
        return result
    }

    /// The Codex desktop app stores user-renamed thread titles as an append-only
    /// index. It can be newer than `state_5.sqlite`, so the last matching entry wins.
    private func attachSessionIndexTitles(
        to metadata: [String: Metadata],
        ids: [String]
    ) -> [String: Metadata] {
        let wanted = Set(ids)
        let indexURL = codexHome.appending(path: "session_index.jsonl")
        guard let data = try? Data(contentsOf: indexURL) else { return metadata }

        var latestNames: [String: String] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String,
                  wanted.contains(id),
                  let name = object["thread_name"] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                latestNames[id] = trimmed
            }
        }

        var result = metadata
        for id in ids {
            guard let title = latestNames[id] else { continue }
            let current = result[id]
            result[id] = Metadata(
                title: title,
                tokensUsed: current?.tokensUsed ?? 0,
                goalStatus: current?.goalStatus
            )
        }
        return result
    }

    private var codexHome: URL {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
