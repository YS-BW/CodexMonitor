import AppKit
import Observation
import SwiftUI

@main
struct CodexMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(store: MonitorStore())
    }
}

@MainActor
private final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: MonitorStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var statusHostingView: PassthroughHostingView<StatusLabel>?
    private var lastPopoverCloseAt = Date.distantPast

    init(store: MonitorStore) {
        self.store = store
        super.init()
        configureStatusItem()
        configurePopover()
        observeStatusContent()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])

        let hostingView = PassthroughHostingView(
            rootView: StatusLabel(snapshot: store.snapshot)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            hostingView.topAnchor.constraint(equalTo: button.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        statusHostingView = hostingView
        updateStatusContent()
    }

    private func configurePopover() {
        let controller = NSHostingController(rootView: MonitorPopover(store: store))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A transient NSPopover closes on mouse-down. The status-item action is
        // delivered on mouse-up; without this guard that same click reopens it.
        guard Date().timeIntervalSince(lastPopoverCloseAt) > 0.25 else { return }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverCloseAt = .now
    }

    private func observeStatusContent() {
        withObservationTracking {
            _ = store.snapshot.statusWindow?.remainingPercent
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusContent()
                self?.observeStatusContent()
            }
        }
    }

    private func updateStatusContent() {
        statusHostingView?.rootView = StatusLabel(
            snapshot: store.snapshot
        )

        let quotaText = store.snapshot.statusWindow.map { "\($0.remainingPercent)%" } ?? "—"
        let font = NSFont.menuBarFont(ofSize: 0)
        let textWidth = ceil((quotaText as NSString).size(withAttributes: [.font: font]).width)
        statusItem.length = 16 + 5 + textWidth + 8
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
