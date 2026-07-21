import AppKit

@MainActor
enum SessionLauncher {
    static func open(_ session: CodexSession, cliTerminal: CLITerminal) {
        open(threadID: session.id, source: session.source, cliTerminal: cliTerminal)
    }

    static func open(threadID: String, source: CodexSession.Source, cliTerminal: CLITerminal) {
        TrackpadHaptics.alignment()

        if source == .cli {
            resumeCLIThread(id: threadID, in: cliTerminal)
        } else if let url = URL(string: "codex://threads/\(threadID)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func resumeCLIThread(id: String, in terminal: CLITerminal) {
        guard isSafeThreadID(id) else { return }

        switch terminal {
        case .terminal:
            let didOpen = runAppleScript("""
            tell application "Terminal"
                activate
                do script "/usr/bin/env zsh -lic 'exec codex resume \(id)'"
            end tell
            """)
            if !didOpen {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: .init()
                )
            }
        case .ghostty:
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
                resumeCLIThread(id: id, in: .terminal)
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [
                "-na", appURL.path, "--args",
                "-e", "/usr/bin/env", "zsh", "-lic", "exec codex resume \(id)"
            ]
            do {
                try process.run()
            } catch {
                resumeCLIThread(id: id, in: .terminal)
            }
        }
    }

    private static func isSafeThreadID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}
