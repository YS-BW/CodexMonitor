import CodexMonitorHookSupport
import Foundation
import Testing

@Test func hookLifecycleAndPrivacy() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let stateURL = directory.appending(path: "state.json")

    let input = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"session","turn_id":"turn","prompt":"private prompt"}"#.utf8)
    let started = CodexHookEvent.decode(input)
    try CodexHookStateStore.apply(event: started, to: stateURL)
    #expect(CodexHookStateStore.read(from: stateURL).effectiveStatus == .thinking)

    try CodexHookStateStore.apply(
        event: CodexHookEvent(name: "PermissionRequest", sessionID: "session", turnID: "turn"),
        to: stateURL
    )
    #expect(CodexHookStateStore.read(from: stateURL).effectiveStatus == .waiting)

    try CodexHookStateStore.apply(
        event: CodexHookEvent(
            name: "PreToolUse",
            sessionID: "session",
            turnID: "turn",
            toolUseID: "tool"
        ),
        to: stateURL
    )
    #expect(CodexHookStateStore.read(from: stateURL).effectiveStatus == .thinking)

    try CodexHookStateStore.apply(
        event: CodexHookEvent(
            name: "PostToolUse",
            sessionID: "session",
            turnID: "turn",
            toolUseID: "tool"
        ),
        to: stateURL
    )
    #expect(CodexHookStateStore.read(from: stateURL).effectiveStatus == .thinking)

    try CodexHookStateStore.apply(
        event: CodexHookEvent(name: "Stop", sessionID: "session", turnID: "turn"),
        to: stateURL
    )
    #expect(CodexHookStateStore.read(from: stateURL).tasks.isEmpty)

    let storedText = try String(contentsOf: stateURL, encoding: .utf8)
    #expect(!storedText.contains("private prompt"))
}

@Test func thinkingHasAVisibleMinimumDuration() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    var snapshot = CodexHookSnapshot()
    snapshot.apply(
        CodexHookEvent(name: "UserPromptSubmit", sessionID: "session", turnID: "turn"),
        now: startedAt
    )
    snapshot.apply(
        CodexHookEvent(
            name: "PreToolUse",
            sessionID: "session",
            turnID: "turn",
            toolUseID: "tool"
        ),
        now: startedAt.addingTimeInterval(0.05)
    )

    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(0.5)) == .thinking)
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(1.2)) == .working)
}

@Test func oneCompletedTaskDoesNotStopAnother() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let stateURL = directory.appending(path: "state.json")

    for (session, turn) in [("a", "1"), ("b", "2")] {
        try CodexHookStateStore.apply(
            event: CodexHookEvent(name: "UserPromptSubmit", sessionID: session, turnID: turn),
            to: stateURL
        )
    }
    try CodexHookStateStore.apply(
        event: CodexHookEvent(name: "Stop", sessionID: "a", turnID: "1"),
        to: stateURL
    )

    let snapshot = CodexHookStateStore.read(from: stateURL)
    #expect(snapshot.effectiveStatus == .thinking)
    #expect(snapshot.tasks.count == 1)
}

@Test func completeLifecycleReturnsToThinkingBetweenWorkAndIdleAtStop() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    var snapshot = CodexHookSnapshot()

    snapshot.apply(
        CodexHookEvent(name: "UserPromptSubmit", sessionID: "session", turnID: "turn"),
        now: startedAt
    )
    #expect(snapshot.effectiveStatus(at: startedAt) == .thinking)

    snapshot.apply(
        CodexHookEvent(
            name: "PreToolUse",
            sessionID: "session",
            turnID: "turn",
            toolUseID: "tool"
        ),
        now: startedAt.addingTimeInterval(2)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(2)) == .working)

    snapshot.apply(
        CodexHookEvent(
            name: "PostToolUse",
            sessionID: "session",
            turnID: "turn",
            toolUseID: "tool"
        ),
        now: startedAt.addingTimeInterval(3)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(3)) == .thinking)

    snapshot.apply(
        CodexHookEvent(name: "PermissionRequest", sessionID: "session", turnID: "turn"),
        now: startedAt.addingTimeInterval(4)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(4)) == .waiting)

    snapshot.apply(
        CodexHookEvent(name: "Stop", sessionID: "session", turnID: "turn"),
        now: startedAt.addingTimeInterval(5)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(5)) == nil)
}

@Test func parallelWorkStaysWorkingUntilEveryActivityFinishes() {
    let startedAt = Date(timeIntervalSince1970: 2_000)
    var snapshot = CodexHookSnapshot()
    snapshot.apply(
        CodexHookEvent(name: "UserPromptSubmit", sessionID: "session", turnID: "turn"),
        now: startedAt
    )
    for toolID in ["one", "two"] {
        snapshot.apply(
            CodexHookEvent(
                name: "PreToolUse",
                sessionID: "session",
                turnID: "turn",
                toolUseID: toolID
            ),
            now: startedAt.addingTimeInterval(2)
        )
    }

    snapshot.apply(
        CodexHookEvent(
            name: "PostToolUse",
            sessionID: "session",
            turnID: "turn",
            toolUseID: "one"
        ),
        now: startedAt.addingTimeInterval(3)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(3)) == .working)

    snapshot.apply(
        CodexHookEvent(
            name: "PostToolUse",
            sessionID: "session",
            turnID: "turn",
            toolUseID: "two"
        ),
        now: startedAt.addingTimeInterval(4)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(4)) == .thinking)
}

@Test func compactionAndSubagentEventsMapBackToThinking() {
    let startedAt = Date(timeIntervalSince1970: 3_000)
    var snapshot = CodexHookSnapshot()
    snapshot.apply(
        CodexHookEvent(name: "PreCompact", sessionID: "session", turnID: "turn"),
        now: startedAt
    )
    #expect(snapshot.effectiveStatus(at: startedAt) == .thinking)

    snapshot.apply(
        CodexHookEvent(
            name: "SubagentStart",
            sessionID: "session",
            turnID: "turn",
            agentID: "agent"
        ),
        now: startedAt.addingTimeInterval(2)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(2)) == .working)

    snapshot.apply(
        CodexHookEvent(
            name: "SubagentStop",
            sessionID: "session",
            turnID: "turn",
            agentID: "agent"
        ),
        now: startedAt.addingTimeInterval(3)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(3)) == .thinking)

    snapshot.apply(
        CodexHookEvent(name: "PostCompact", sessionID: "session", turnID: "turn"),
        now: startedAt.addingTimeInterval(4)
    )
    #expect(snapshot.effectiveStatus(at: startedAt.addingTimeInterval(4)) == .thinking)
}

@Test func sessionStartClearsAStaleTaskForThatSessionOnly() {
    let startedAt = Date(timeIntervalSince1970: 4_000)
    var snapshot = CodexHookSnapshot()
    for session in ["old", "other"] {
        snapshot.apply(
            CodexHookEvent(name: "UserPromptSubmit", sessionID: session, turnID: "turn"),
            now: startedAt
        )
    }
    snapshot.apply(
        CodexHookEvent(name: "SessionStart", sessionID: "old", turnID: nil),
        now: startedAt.addingTimeInterval(1)
    )

    #expect(snapshot.tasks.values.contains(where: { $0.sessionID == "old" }) == false)
    #expect(snapshot.tasks.values.contains(where: { $0.sessionID == "other" }))
}

@Test func staleTasksAreInactiveWithoutAnotherHookEvent() {
    let startedAt = Date(timeIntervalSince1970: 10_000)
    var snapshot = CodexHookSnapshot()
    snapshot.apply(
        CodexHookEvent(name: "UserPromptSubmit", sessionID: "session", turnID: "turn"),
        now: startedAt
    )

    let beforeExpiry = startedAt.addingTimeInterval(CodexHookSnapshot.staleTaskDuration - 1)
    let atExpiry = startedAt.addingTimeInterval(CodexHookSnapshot.staleTaskDuration)
    let afterExpiry = startedAt.addingTimeInterval(CodexHookSnapshot.staleTaskDuration + 1)
    #expect(snapshot.effectiveStatus(at: beforeExpiry) == .thinking)
    #expect(snapshot.effectiveStatus(at: atExpiry) == nil)
    #expect(snapshot.effectiveStatus(at: afterExpiry) == nil)
    #expect(snapshot.nextTaskExpiration(after: startedAt) == startedAt.addingTimeInterval(CodexHookSnapshot.staleTaskDuration))
}

@Test func readingStatePrunesExpiredTasksAndOldSchemaStillDecodes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let stateURL = directory.appending(path: "state.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let updatedAt = Date(timeIntervalSince1970: 20_000)
    let json = """
    {
      "version": 1,
      "updatedAt": "1970-01-01T05:33:20Z",
      "lastEventName": "UserPromptSubmit",
      "lastPromptAt": "1970-01-01T05:33:20Z",
      "tasks": {
        "session:turn": {
          "sessionID": "session",
          "turnID": "turn",
          "status": "thinking",
          "updatedAt": "1970-01-01T05:33:20Z",
          "activeWorkIDs": []
        }
      }
    }
    """
    try Data(json.utf8).write(to: stateURL)

    let live = CodexHookStateStore.read(from: stateURL, now: updatedAt)
    #expect(live.tasks["session:turn"]?.transcriptPath == nil)
    let expired = CodexHookStateStore.read(
        from: stateURL,
        now: updatedAt.addingTimeInterval(CodexHookSnapshot.staleTaskDuration + 1)
    )
    #expect(expired.tasks.isEmpty)
    #expect(expired.effectiveStatus == nil)
}

@Test func transcriptPathIsDecodedAndRetainedAcrossEvents() {
    let input = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"session","turn_id":"turn","transcript_path":"/tmp/session.jsonl"}"#.utf8)
    let event = CodexHookEvent.decode(input)
    var snapshot = CodexHookSnapshot()
    snapshot.apply(event, now: Date(timeIntervalSince1970: 30_000))
    snapshot.apply(
        CodexHookEvent(
            name: "PreToolUse",
            sessionID: "session",
            turnID: "turn",
            toolUseID: "tool"
        ),
        now: Date(timeIntervalSince1970: 30_001)
    )

    #expect(snapshot.tasks["session:turn"]?.transcriptPath == "/tmp/session.jsonl")
}

@Test func terminalRemovalTargetsOnlyTheMatchingTurn() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let stateURL = directory.appending(path: "state.json")
    for (session, turn) in [("aborted", "a"), ("completed", "b")] {
        try CodexHookStateStore.apply(
            event: CodexHookEvent(name: "UserPromptSubmit", sessionID: session, turnID: turn),
            to: stateURL
        )
    }
    try CodexHookStateStore.apply(
        event: CodexHookEvent(name: "Stop", sessionID: "completed", turnID: "b"),
        to: stateURL
    )
    #expect(try CodexHookStateStore.removeTask(sessionID: "aborted", turnID: "wrong", from: stateURL) == false)
    #expect(CodexHookStateStore.read(from: stateURL).tasks.count == 1)
    #expect(try CodexHookStateStore.removeTask(sessionID: "aborted", turnID: "a", from: stateURL))
    #expect(CodexHookStateStore.read(from: stateURL).tasks.isEmpty)
}

@Test func sessionEndClearsOnlyItsSession() {
    let startedAt = Date(timeIntervalSince1970: 40_000)
    var snapshot = CodexHookSnapshot()
    for session in ["ended", "other"] {
        snapshot.apply(
            CodexHookEvent(name: "UserPromptSubmit", sessionID: session, turnID: "turn"),
            now: startedAt
        )
    }
    snapshot.apply(
        CodexHookEvent(name: "SessionEnd", sessionID: "ended", turnID: nil),
        now: startedAt.addingTimeInterval(1)
    )

    #expect(snapshot.tasks.values.contains(where: { $0.sessionID == "ended" }) == false)
    #expect(snapshot.tasks.values.contains(where: { $0.sessionID == "other" }))
}
