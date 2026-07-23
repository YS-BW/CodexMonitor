import CodexMonitorHookSupport
import Foundation
import XCTest
@testable import CodexMonitor

final class CodexTranscriptTerminalMonitorTests: XCTestCase {
    func testParserKeepsPartialLinesAndReturnsOnlyTerminalTurns() {
        var buffer = Data(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"done"}}"#.utf8)
        buffer.append(0x0A)
        buffer.append(Data(#"{"type":"event_msg","payload":{"type":"token_count"}}"#.utf8))
        buffer.append(0x0A)
        buffer.append(Data(#"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"abort"}}"#.utf8))

        XCTAssertEqual(
            CodexTranscriptTerminalParser.consumeCompleteLines(from: &buffer),
            ["done"]
        )
        XCTAssertFalse(buffer.isEmpty)
        buffer.append(0x0A)
        XCTAssertEqual(
            CodexTranscriptTerminalParser.consumeCompleteLines(from: &buffer),
            ["abort"]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testMonitorReconcilesTerminalEventAlreadyInTranscriptTail() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appending(path: "session.jsonl")
        var initialData = Data(#"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn"}}"#.utf8)
        initialData.append(0x0A)
        try initialData.write(to: transcriptURL)

        let expectation = expectation(description: "terminal event")
        let results = TerminalResults()
        let monitor = CodexTranscriptTerminalMonitor(initialTailByteCount: 4_096)
        monitor.onTerminal = { terminal in
            results.append(terminal)
            expectation.fulfill()
        }
        monitor.synchronize(tasks: [
            CodexHookTask(
                sessionID: "session",
                turnID: "turn",
                status: .thinking,
                updatedAt: .now,
                transcriptPath: transcriptURL.path
            ),
        ])

        wait(for: [expectation], timeout: 2)
        monitor.stop()
        XCTAssertEqual(results.values, [CodexTranscriptTerminal(sessionID: "session", turnID: "turn")])
    }

    func testMonitorReadsAppendedTerminalEventAndIgnoresOtherTurns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appending(path: "session.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: transcriptURL.path, contents: Data()))

        let expectation = expectation(description: "matching terminal event")
        let results = TerminalResults()
        let monitor = CodexTranscriptTerminalMonitor()
        monitor.onTerminal = { terminal in
            results.append(terminal)
            expectation.fulfill()
        }
        monitor.synchronize(tasks: [
            CodexHookTask(
                sessionID: "session",
                turnID: "target",
                status: .working,
                updatedAt: .now,
                transcriptPath: transcriptURL.path
            ),
        ])

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            var data = Data(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"other"}}"#.utf8)
            data.append(0x0A)
            data.append(Data(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"target"}}"#.utf8))
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: transcriptURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }

        wait(for: [expectation], timeout: 2)
        monitor.stop()
        XCTAssertEqual(results.values, [CodexTranscriptTerminal(sessionID: "session", turnID: "target")])
    }

    func testTranscriptTerminalRemovesPersistedTask() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriptURL = directory.appending(path: "session.jsonl")
        let stateURL = directory.appending(path: "state.json")
        var transcriptData = Data(#"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn"}}"#.utf8)
        transcriptData.append(0x0A)
        try transcriptData.write(to: transcriptURL)
        try CodexHookStateStore.apply(
            event: CodexHookEvent(
                name: "UserPromptSubmit",
                sessionID: "session",
                turnID: "turn",
                transcriptPath: transcriptURL.path
            ),
            to: stateURL
        )

        let expectation = expectation(description: "persisted task removed")
        let monitor = CodexTranscriptTerminalMonitor()
        monitor.onTerminal = { terminal in
            _ = try? CodexHookStateStore.removeTask(
                sessionID: terminal.sessionID,
                turnID: terminal.turnID,
                from: stateURL
            )
            expectation.fulfill()
        }
        monitor.synchronize(tasks: Array(CodexHookStateStore.read(from: stateURL).tasks.values))

        wait(for: [expectation], timeout: 2)
        monitor.stop()
        XCTAssertTrue(CodexHookStateStore.read(from: stateURL).tasks.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class TerminalResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexTranscriptTerminal] = []

    var values: [CodexTranscriptTerminal] {
        lock.withLock { storage }
    }

    func append(_ terminal: CodexTranscriptTerminal) {
        lock.withLock {
            storage.append(terminal)
        }
    }
}
