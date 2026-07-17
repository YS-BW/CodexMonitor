import AppKit

@MainActor
enum SessionLauncher {
    static func open(_ session: CodexSession, cliTerminal: CLITerminal) {
        TrackpadHaptics.alignment()

        if session.source == .cli {
            resumeCLIThread(id: session.id, in: cliTerminal)
        } else if let url = URL(string: "codex://threads/\(session.id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func resumeCLIThread(id: String, in terminal: CLITerminal) {
        guard isSafeThreadID(id) else { return }

        switch terminal {
        case .terminal:
            runAppleScript("""
            tell application "Terminal"
                activate
                do script "codex resume \(id); exec zsh -l"
            end tell
            """)
        case .ghostty:
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil else {
                resumeCLIThread(id: id, in: .terminal)
                return
            }
            runAppleScript("""
            tell application "Ghostty"
                set cfg to new surface configuration
                set command of cfg to "shell:codex resume \(id); exec zsh -l"
                new window with configuration cfg
                activate
            end tell
            """)
        }
    }

    private static func isSafeThreadID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
