import Foundation

/// Local Codex token accounting adapted from CodexBar's MIT-licensed
/// `CostUsageScanner`. This keeps the parts relevant to Codex Monitor:
/// cumulative-watermark containment, fork inheritance and a persistent cache.
struct CodexTokenUsageScanner: Sendable {
    func report(trendDays: Int, now: Date) -> TokenUsageReport {
        guard trendDays > 0 else { return .empty }

        let files = sessionFiles()
        let signatures = files.compactMap(fileSignature).sorted { $0.path < $1.path }
        let calendar = Calendar.autoupdatingCurrent
        let dayAnchor = calendar.startOfDay(for: now)
        let cached = loadCache()
        if let cached,
           cached.version == CachePayload.currentVersion,
           cached.trendDays == trendDays,
           cached.dayAnchor == dayAnchor.timeIntervalSince1970,
           cached.files == signatures {
            return cached.report
        }

        let cachedFiles = Dictionary(
            uniqueKeysWithValues: (cached?.parsedFiles ?? []).map { ($0.signature.path, $0) }
        )
        var parsedFiles: [CachedFile] = []
        var parsedSessions: [SessionLog] = []
        parsedFiles.reserveCapacity(signatures.count)
        parsedSessions.reserveCapacity(signatures.count)
        for signature in signatures {
            if let cachedFile = cachedFiles[signature.path], cachedFile.signature == signature {
                parsedFiles.append(cachedFile)
                if let session = cachedFile.session { parsedSessions.append(session) }
                continue
            }
            let session = parse(file: URL(fileURLWithPath: signature.path))
            parsedFiles.append(CachedFile(signature: signature, session: session))
            if let session { parsedSessions.append(session) }
        }

        let sessions = canonicalSessions(from: parsedSessions)
        var totals = Totals.zero
        var eventCount = 0
        var daily: [Date: Int] = [:]
        var todayTokens = 0
        var weekTokens = 0
        var monthTokens = 0
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayAnchor
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? dayAnchor
        guard let firstDay = calendar.date(byAdding: .day, value: -(trendDays - 1), to: dayAnchor) else {
            return .empty
        }
        for offset in 0..<trendDays {
            if let day = calendar.date(byAdding: .day, value: offset, to: firstDay) {
                daily[day] = 0
            }
        }

        for session in sessions.values {
            let inherited = inheritedTotals(for: session, sessions: sessions)
            var accumulator = Accumulator(
                inherited: inherited,
                isResolvedFork: session.parentID != nil && inherited != nil
            )
            for event in session.events {
                let delta = accumulator.consume(last: event.last, total: event.total)
                guard !delta.isZero else { continue }
                totals = totals + delta
                eventCount += 1
                let day = calendar.startOfDay(for: event.date)
                if daily[day] != nil {
                    daily[day, default: 0] += delta.total
                }
                if calendar.isDate(event.date, inSameDayAs: now) {
                    todayTokens += delta.total
                }
                if event.date >= weekStart, event.date <= now {
                    weekTokens += delta.total
                }
                if event.date >= monthStart, event.date <= now {
                    monthTokens += delta.total
                }
            }
        }

        let result = TokenUsageReport(
            summary: TokenSummary(
                totalTokens: totals.total,
                inputTokens: totals.input,
                cachedInputTokens: totals.cached,
                outputTokens: totals.output,
                reasoningOutputTokens: totals.reasoning,
                eventCount: eventCount
            ),
            trend: TokenTrend(days: daily.keys.sorted().map {
                TokenTrend.Day(date: $0, tokens: daily[$0, default: 0])
            }),
            periods: TokenPeriodSummary(
                todayTokens: todayTokens,
                weekTokens: weekTokens,
                monthTokens: monthTokens
            )
        )
        saveCache(CachePayload(
            version: CachePayload.currentVersion,
            trendDays: trendDays,
            dayAnchor: dayAnchor.timeIntervalSince1970,
            files: signatures,
            parsedFiles: parsedFiles,
            report: result
        ))
        return result
    }

    private func sessionFiles() -> [URL] {
        let fileManager = FileManager.default
        let codexHomePath = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: ".codex").path
        let codexHome = URL(fileURLWithPath: codexHomePath, isDirectory: true)
        let roots = ["sessions", "archived_sessions"].map {
            codexHome.appending(path: $0, directoryHint: .isDirectory)
        }
        var files: [URL] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                files.append(file)
            }
        }
        return files
    }

    private func fileSignature(_ file: URL) -> FileSignature? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return FileSignature(path: file.path, size: Int64(size), modified: modified.timeIntervalSince1970)
    }

    private func canonicalSessions(from parsedSessions: [SessionLog]) -> [String: SessionLog] {
        var sessions: [String: SessionLog] = [:]
        for parsed in parsedSessions {
            if let existing = sessions[parsed.id], existing.events.count >= parsed.events.count {
                continue
            }
            sessions[parsed.id] = parsed
        }
        return sessions
    }

    private func parse(file: URL) -> SessionLog? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        var id = sessionID(from: file)
        var parentID: String?
        var forkDate: Date?
        var capturedMetadata = false
        var events: [TokenEvent] = []

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }

            if type == "session_meta", !capturedMetadata {
                capturedMetadata = true
                id = string(payload["id"]) ?? string(payload["session_id"]) ?? id
                parentID = string(payload["forked_from_id"])
                    ?? string(payload["forkedFromId"])
                    ?? string(payload["parent_session_id"])
                    ?? string(payload["parentSessionId"])
                let timestamp = string(payload["fork_timestamp"])
                    ?? string(payload["forkTimestamp"])
                    ?? string(payload["timestamp"])
                    ?? string(object["timestamp"])
                forkDate = timestamp.flatMap { parseDate($0, fractional: fractional, standard: standard) }
                continue
            }

            guard type == "event_msg",
                  string(payload["type"]) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let timestamp = string(object["timestamp"]),
                  let date = parseDate(timestamp, fractional: fractional, standard: standard) else { continue }
            let last = (info["last_token_usage"] as? [String: Any]).map(totals)
            let total = (info["total_token_usage"] as? [String: Any]).map(totals)
            if last != nil || total != nil {
                events.append(TokenEvent(date: date, last: last, total: total))
            }
        }
        guard !id.isEmpty else { return nil }
        return SessionLog(id: id, parentID: parentID, forkDate: forkDate, events: events)
    }

    private func inheritedTotals(for session: SessionLog, sessions: [String: SessionLog]) -> Totals? {
        guard let parentID = session.parentID, let parent = sessions[parentID] else { return nil }
        let candidates: [TokenEvent]
        if let forkDate = session.forkDate {
            candidates = parent.events.filter { $0.date <= forkDate }
        } else {
            candidates = parent.events
        }
        return candidates.reversed().compactMap(\.total).first
    }

    private func sessionID(from file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let range = name.range(of: pattern, options: .regularExpression) else { return file.path }
        return String(name[range]).lowercased()
    }

    private func totals(_ value: [String: Any]) -> Totals {
        Totals(
            input: integer(value["input_tokens"]),
            cached: integer(value["cached_input_tokens"]),
            output: integer(value["output_tokens"]),
            reasoning: integer(value["reasoning_output_tokens"])
        )
    }

    private func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private func parseDate(
        _ value: String,
        fractional: ISO8601DateFormatter,
        standard: ISO8601DateFormatter
    ) -> Date? {
        fractional.date(from: value) ?? standard.date(from: value)
    }

    private func loadCache() -> CachePayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    private func saveCache(_ cache: CachePayload) {
        let fileManager = FileManager.default
        let folder = cacheURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "CodexMonitor/token-usage-v3.json")
    }
}

private struct Accumulator {
    private var counted: Totals?
    private var rawBaseline: Totals?
    private var watermark: Totals?
    private var seenRawTotals = Set<Totals>()
    private var sawDivergentTotals = false
    private var sawInterleavedTotals = false
    private var remainingInherited: Totals?
    private let inherited: Totals?
    private let isResolvedFork: Bool

    init(inherited: Totals?, isResolvedFork: Bool) {
        self.inherited = inherited
        self.remainingInherited = inherited
        self.isResolvedFork = isResolvedFork
    }

    mutating func consume(last: Totals?, total rawTotal: Totals?) -> Totals {
        let adjustedTotal = rawTotal.map { isResolvedFork ? $0.subtracting(inherited ?? .zero) : $0 }
        if let adjustedTotal {
            if seenRawTotals.contains(adjustedTotal) { return .zero }
            if let watermark, adjustedTotal.hasComponent(below: watermark) {
                sawInterleavedTotals = true
            }
        }

        let baseline = watermark ?? rawBaseline
        let base = counted ?? .zero
        var delta = Totals.zero

        if isResolvedFork, let adjustedTotal {
            delta = sawInterleavedTotals
                ? containedDelta(watermark: baseline, counted: counted, current: adjustedTotal)
                : totalDelta(from: baseline, to: adjustedTotal)
            remainingInherited = nil
        } else if let last {
            var adjustedLast = subtractRemainingInheritance(from: last)
            if let adjustedTotal {
                if sawInterleavedTotals {
                    adjustedLast = postLatchDelta(
                        watermark: baseline,
                        counted: counted,
                        current: adjustedTotal,
                        last: adjustedLast
                    )
                } else {
                    let fromTotal = totalDelta(from: baseline, to: adjustedTotal)
                    if !sawDivergentTotals,
                       adjustedTotal.isAtLeast(baseline ?? .zero),
                       fromTotal.isAtMost(last) {
                        adjustedLast = fromTotal
                    }
                }
                rawBaseline = adjustedTotal
            } else {
                rawBaseline = base + adjustedLast
            }
            delta = adjustedLast
        } else if let adjustedTotal {
            delta = sawInterleavedTotals
                ? containedDelta(watermark: baseline, counted: counted, current: adjustedTotal)
                : divergentOrNormalDelta(current: adjustedTotal)
            rawBaseline = adjustedTotal
        }

        counted = base + delta
        if let adjustedTotal {
            if adjustedTotal != counted { sawDivergentTotals = true }
            watermark = watermark.map { $0.maximum(adjustedTotal) } ?? adjustedTotal
            seenRawTotals.insert(adjustedTotal)
            if seenRawTotals.count > 64, let first = seenRawTotals.first {
                seenRawTotals.remove(first)
            }
        } else if let counted {
            watermark = watermark.map { $0.maximum(counted) } ?? counted
        }
        return delta
    }

    private mutating func subtractRemainingInheritance(from last: Totals) -> Totals {
        guard let remainingInherited else { return last }
        let adjusted = last.subtracting(remainingInherited)
        self.remainingInherited = remainingInherited.subtracting(last)
        return adjusted
    }

    private func divergentOrNormalDelta(current: Totals) -> Totals {
        guard sawDivergentTotals else { return totalDelta(from: watermark ?? rawBaseline, to: current) }
        let raw = rawBaseline ?? .zero
        let logical = counted ?? .zero
        return Totals.componentwise { index in
            let currentValue = current[index]
            return currentValue >= raw[index]
                ? max(0, currentValue - raw[index])
                : max(0, currentValue - logical[index])
        }
    }

    private func totalDelta(from baseline: Totals?, to current: Totals) -> Totals {
        current.subtracting(baseline ?? .zero)
    }

    private func containedDelta(watermark: Totals?, counted: Totals?, current: Totals) -> Totals {
        let water = watermark ?? .zero
        let counted = counted ?? .zero
        return Totals.componentwise { index in
            let currentValue = current[index]
            if currentValue >= water[index] {
                return max(0, currentValue - max(water[index], counted[index]))
            }
            return max(0, currentValue - counted[index])
        }
    }

    private func postLatchDelta(
        watermark: Totals?,
        counted: Totals?,
        current: Totals,
        last: Totals
    ) -> Totals {
        containedDelta(watermark: watermark, counted: counted, current: current).minimum(last)
    }
}

private struct Totals: Codable, Hashable {
    var input: Int
    var cached: Int
    var output: Int
    var reasoning: Int

    static let zero = Totals(input: 0, cached: 0, output: 0, reasoning: 0)
    var total: Int { input + output }
    var isZero: Bool { input == 0 && cached == 0 && output == 0 && reasoning == 0 }

    subscript(_ index: Int) -> Int {
        switch index {
        case 0: input
        case 1: cached
        case 2: output
        default: reasoning
        }
    }

    static func + (lhs: Totals, rhs: Totals) -> Totals {
        Totals(
            input: lhs.input + rhs.input,
            cached: lhs.cached + rhs.cached,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    static func componentwise(_ transform: (Int) -> Int) -> Totals {
        Totals(input: transform(0), cached: transform(1), output: transform(2), reasoning: transform(3))
    }

    func subtracting(_ other: Totals) -> Totals {
        Totals.componentwise { max(0, self[$0] - other[$0]) }
    }

    func maximum(_ other: Totals) -> Totals {
        Totals.componentwise { max(self[$0], other[$0]) }
    }

    func minimum(_ other: Totals) -> Totals {
        Totals.componentwise { min(self[$0], other[$0]) }
    }

    func isAtLeast(_ other: Totals) -> Bool {
        (0..<4).allSatisfy { self[$0] >= other[$0] }
    }

    func isAtMost(_ other: Totals) -> Bool {
        (0..<4).allSatisfy { self[$0] <= other[$0] }
    }

    func hasComponent(below other: Totals) -> Bool {
        (0..<4).contains { self[$0] < other[$0] }
    }
}

private struct TokenEvent: Codable {
    let date: Date
    let last: Totals?
    let total: Totals?
}

private struct SessionLog: Codable {
    let id: String
    let parentID: String?
    let forkDate: Date?
    let events: [TokenEvent]
}

private struct FileSignature: Codable, Equatable {
    let path: String
    let size: Int64
    let modified: TimeInterval
}

private struct CachedFile: Codable {
    let signature: FileSignature
    let session: SessionLog?
}

private struct CachePayload: Codable {
    static let currentVersion = 5

    let version: Int
    let trendDays: Int
    let dayAnchor: TimeInterval
    let files: [FileSignature]
    let parsedFiles: [CachedFile]
    private let summary: CachedSummary
    private let days: [CachedDay]
    private let periods: CachedPeriods

    init(
        version: Int,
        trendDays: Int,
        dayAnchor: TimeInterval,
        files: [FileSignature],
        parsedFiles: [CachedFile],
        report: TokenUsageReport
    ) {
        self.version = version
        self.trendDays = trendDays
        self.dayAnchor = dayAnchor
        self.files = files
        self.parsedFiles = parsedFiles
        self.summary = CachedSummary(report.summary)
        self.days = report.trend.days.map { CachedDay(date: $0.date, tokens: $0.tokens) }
        self.periods = CachedPeriods(report.periods)
    }

    var report: TokenUsageReport {
        TokenUsageReport(
            summary: summary.value,
            trend: TokenTrend(days: days.map { TokenTrend.Day(date: $0.date, tokens: $0.tokens) }),
            periods: periods.value
        )
    }
}

private struct CachedSummary: Codable {
    let total: Int
    let input: Int
    let cached: Int
    let output: Int
    let reasoning: Int
    let events: Int

    init(_ value: TokenSummary) {
        total = value.totalTokens
        input = value.inputTokens
        cached = value.cachedInputTokens
        output = value.outputTokens
        reasoning = value.reasoningOutputTokens
        events = value.eventCount
    }

    var value: TokenSummary {
        TokenSummary(
            totalTokens: total,
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            eventCount: events
        )
    }
}

private struct CachedDay: Codable {
    let date: Date
    let tokens: Int
}

private struct CachedPeriods: Codable {
    let today: Int
    let week: Int
    let month: Int

    init(_ value: TokenPeriodSummary) {
        today = value.todayTokens
        week = value.weekTokens
        month = value.monthTokens
    }

    var value: TokenPeriodSummary {
        TokenPeriodSummary(todayTokens: today, weekTokens: week, monthTokens: month)
    }
}
