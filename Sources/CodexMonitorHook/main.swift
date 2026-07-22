import CodexMonitorHookSupport
import Foundation

let fallbackEventName = CommandLine.arguments.dropFirst().first
let input = FileHandle.standardInput.readDataToEndOfFile()
let event = CodexHookEvent.decode(input, fallbackName: fallbackEventName)

guard !event.name.isEmpty else {
    exit(0)
}

do {
    try CodexHookStateStore.apply(event: event)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("Codex Monitor hook failed\n".utf8))
    exit(1)
}
