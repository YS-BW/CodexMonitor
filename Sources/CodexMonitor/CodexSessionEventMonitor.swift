import Foundation

/// Watches Codex's session tree with one kernel-backed FSEvents stream.
/// No timer is used: the app wakes only when a rollout file actually changes.
final class CodexSessionEventMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ysbw.CodexMonitor.session-events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pendingUpdate: DispatchWorkItem?
    var onChange: (@Sendable () -> Void)?

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }
        let fileManager = FileManager.default
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: ".codex").path
        let sessionsRoot = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appending(path: "sessions", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: sessionsRoot.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            codexSessionEventCallback,
            &context,
            [sessionsRoot.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func stop() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func sessionFilesDidChange() {
        pendingUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        pendingUpdate = update
        queue.asyncAfter(deadline: .now() + 0.15, execute: update)
    }
}

private func codexSessionEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ context: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let context else { return }
    Unmanaged<CodexSessionEventMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .sessionFilesDidChange()
}
