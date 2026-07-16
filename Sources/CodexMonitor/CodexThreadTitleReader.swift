import Foundation
import SQLite3

struct CodexThreadTitleReader: Sendable {
    func titles(for ids: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }

        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/state_5.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return [:] }
        defer { sqlite3_close(database) }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT id, title FROM threads WHERE id IN (\(placeholders)) AND title <> ''"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, sqliteTransient)
        }

        var titles: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW,
              let idPointer = sqlite3_column_text(statement, 0),
              let titlePointer = sqlite3_column_text(statement, 1) {
            let id = String(cString: idPointer)
            let title = String(cString: titlePointer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titles[id] = title }
        }
        return titles
    }
}
