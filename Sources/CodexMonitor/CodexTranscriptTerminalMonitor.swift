import CodexMonitorHookSupport
import Darwin
import Foundation

struct CodexTranscriptTerminal: Equatable, Sendable {
    let sessionID: String
    let turnID: String
}

enum CodexTranscriptTerminalParser {
    static func consumeCompleteLines(from buffer: inout Data) -> [String] {
        var turnIDs: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(line)),
                  envelope.type == "event_msg",
                  envelope.payload.type == "task_complete" || envelope.payload.type == "turn_aborted",
                  let turnID = envelope.payload.turnID,
                  !turnID.isEmpty
            else { continue }
            turnIDs.append(turnID)
        }
        return turnIDs
    }

    private struct Envelope: Decodable {
        let type: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let type: String
        let turnID: String?

        enum CodingKeys: String, CodingKey {
            case type
            case turnID = "turn_id"
        }
    }
}

final class CodexTranscriptTerminalMonitor: @unchecked Sendable {
    private final class FileWatcher {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
        var sessionsByTurnID: [String: String]
        var pending = Data()

        init(
            descriptor: Int32,
            source: DispatchSourceFileSystemObject,
            sessionsByTurnID: [String: String]
        ) {
            self.descriptor = descriptor
            self.source = source
            self.sessionsByTurnID = sessionsByTurnID
        }
    }

    private let queue = DispatchQueue(label: "com.ysbw.CodexMonitor.transcript-terminal", qos: .utility)
    private let initialTailByteCount: Int64
    private var desiredTasks: [URL: [String: String]] = [:]
    private var watchers: [URL: FileWatcher] = [:]
    var onTerminal: (@Sendable (CodexTranscriptTerminal) -> Void)?

    init(initialTailByteCount: Int64 = 1_048_576) {
        self.initialTailByteCount = initialTailByteCount
    }

    deinit {
        watchers.values.forEach { $0.source.cancel() }
    }

    func synchronize(tasks: [CodexHookTask]) {
        var grouped: [URL: [String: String]] = [:]
        for task in tasks {
            guard let transcriptPath = task.transcriptPath, !transcriptPath.isEmpty else { continue }
            let url = URL(fileURLWithPath: transcriptPath)
            grouped[url, default: [:]][task.turnID] = task.sessionID
        }

        let desired = grouped
        queue.async { [weak self] in
            self?.applyDesiredTasks(desired)
        }
    }

    func stop() {
        queue.sync {
            desiredTasks.removeAll()
            for watcher in watchers.values {
                watcher.source.cancel()
            }
            watchers.removeAll()
        }
    }

    private func applyDesiredTasks(_ tasks: [URL: [String: String]]) {
        desiredTasks = tasks

        for url in watchers.keys where tasks[url] == nil {
            watchers.removeValue(forKey: url)?.source.cancel()
        }
        for (url, sessionsByTurnID) in tasks {
            if let watcher = watchers[url] {
                watcher.sessionsByTurnID = sessionsByTurnID
            } else {
                installWatcher(for: url, sessionsByTurnID: sessionsByTurnID)
            }
        }
    }

    private func installWatcher(for url: URL, sessionsByTurnID: [String: String]) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        let watcher = FileWatcher(
            descriptor: descriptor,
            source: source,
            sessionsByTurnID: sessionsByTurnID
        )
        watchers[url] = watcher

        let fileSize = Darwin.lseek(descriptor, 0, SEEK_END)
        if fileSize >= 0 {
            let startOffset = max(0, fileSize - initialTailByteCount)
            let readOffset = startOffset > 0 ? startOffset - 1 : 0
            if Darwin.lseek(descriptor, readOffset, SEEK_SET) >= 0 {
                watcher.pending = readAvailable(from: descriptor)
                if startOffset > 0 {
                    if watcher.pending.first == 0x0A {
                        watcher.pending.removeFirst()
                    } else {
                        discardFirstPartialLine(from: &watcher.pending)
                    }
                }
                emitTerminalEvents(from: watcher)
            }
        }

        source.setEventHandler { [weak self] in
            self?.handleEvent(for: url)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.resume()
    }

    private func handleEvent(for url: URL) {
        guard let watcher = watchers[url] else { return }
        let events = watcher.source.data
        if events.contains(.delete) || events.contains(.rename) {
            watcher.source.cancel()
            watchers.removeValue(forKey: url)
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let tasks = desiredTasks[url], watchers[url] == nil else { return }
                installWatcher(for: url, sessionsByTurnID: tasks)
            }
            return
        }

        var info = stat()
        let currentOffset = Darwin.lseek(watcher.descriptor, 0, SEEK_CUR)
        if currentOffset >= 0,
           Darwin.fstat(watcher.descriptor, &info) == 0,
           info.st_size < currentOffset {
            _ = Darwin.lseek(watcher.descriptor, 0, SEEK_SET)
            watcher.pending.removeAll(keepingCapacity: true)
        }

        watcher.pending.append(readAvailable(from: watcher.descriptor))
        emitTerminalEvents(from: watcher)
    }

    private func emitTerminalEvents(from watcher: FileWatcher) {
        for turnID in CodexTranscriptTerminalParser.consumeCompleteLines(from: &watcher.pending) {
            guard let sessionID = watcher.sessionsByTurnID[turnID] else { continue }
            onTerminal?(CodexTranscriptTerminal(sessionID: sessionID, turnID: turnID))
        }
    }

    private func readAvailable(from descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func discardFirstPartialLine(from data: inout Data) {
        guard let newline = data.firstIndex(of: 0x0A) else {
            data.removeAll()
            return
        }
        data.removeSubrange(...newline)
    }
}
