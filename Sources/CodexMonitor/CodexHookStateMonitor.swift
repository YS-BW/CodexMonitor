import CodexMonitorHookSupport
import Darwin
import Foundation

final class CodexHookStateMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ysbw.CodexMonitor.hook-state", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var pendingRead: DispatchWorkItem?
    private var descriptor: Int32 = -1
    var onChange: (@Sendable (CodexHookSnapshot) -> Void)?

    deinit {
        stop()
    }

    func start() {
        guard source == nil else { return }
        let stateURL = CodexHookStateStore.stateURL()
        let directory = stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            pendingRead?.cancel()
            let read = DispatchWorkItem { [weak self] in
                self?.onChange?(CodexHookStateStore.read())
            }
            pendingRead = read
            queue.asyncAfter(deadline: .now() + 0.05, execute: read)
        }
        source.setCancelHandler { [descriptor] in
            Darwin.close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        pendingRead?.cancel()
        pendingRead = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
