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

        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/state_5.sqlite")
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
            let tokensUsed = Int(sqlite3_column_int64(statement, 2))
            metadata[id] = Metadata(
                title: title?.isEmpty == false ? title : nil,
                tokensUsed: tokensUsed,
                goalStatus: nil
            )
        }
        return attachGoalStatuses(to: metadata, ids: ids)
    }

    func totalTokens() -> TokenSummary {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/state_5.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return .empty }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COALESCE(SUM(tokens_used), 0) FROM threads", -1, &statement, nil) == SQLITE_OK,
              let statement else { return .empty }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return .empty }
        return TokenSummary(totalTokens: Int(sqlite3_column_int64(statement, 0)))
    }

    /// Builds a daily usage trend from Codex's token-count events. Each event
    /// records the per-thread cumulative total, so only its increase is added.
    func recentTokenTrend(days: Int = 7, now: Date = .now) -> TokenTrend {
        let calendar = Calendar.autoupdatingCurrent
        guard let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else {
            return .empty
        }

        var totals = Dictionary(uniqueKeysWithValues: (0..<days).compactMap { offset -> (Date, Int)? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return (date, 0)
        })

        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let root = URL(fileURLWithPath: home, isDirectory: true).appending(path: "sessions", directoryHint: .isDirectory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let fileManager = FileManager.default
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for offset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let folder = root.appending(path: formatter.string(from: date), directoryHint: .isDirectory)
            guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }

            for file in files where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                guard let data = try? Data(contentsOf: file) else { continue }
                var previousTotal: Int?

                for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          object["type"] as? String == "event_msg",
                          let payload = object["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let totalUsage = info["total_token_usage"] as? [String: Any],
                          let total = totalUsage["total_tokens"] as? Int,
                          let timestamp = object["timestamp"] as? String,
                          let eventDate = timestampFormatter.date(from: timestamp)
                    else { continue }

                    let delta = max(0, total - (previousTotal ?? 0))
                    previousTotal = total
                    let day = calendar.startOfDay(for: eventDate)
                    if totals[day] != nil {
                        totals[day, default: 0] += delta
                    }
                }
            }
        }

        let result = totals.keys.sorted().map { TokenTrend.Day(date: $0, tokens: totals[$0, default: 0]) }
        return TokenTrend(days: result)
    }

    private func attachGoalStatuses(to metadata: [String: Metadata], ids: [String]) -> [String: Metadata] {
        let goalsURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/goals_1.sqlite")
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
}
