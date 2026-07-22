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
