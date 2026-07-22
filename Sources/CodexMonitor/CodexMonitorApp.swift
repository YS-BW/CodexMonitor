import AppKit
import Observation
import SwiftUI

private enum LegacyDefaultsMigration {
    private static let temporaryMenuBarDomain = "com.ysbw.CodexMonitor.MenuBar"
    private static let migrationKey = "didMigrateTemporaryMenuBarDefaultsV1"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        if let temporaryValues = defaults.persistentDomain(forName: temporaryMenuBarDomain) {
            for (key, value) in temporaryValues where !key.hasPrefix("NSStatusItem ") {
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }
}

@MainActor
private enum StatusItemPlacement {
    static let autosaveName = "codex-monitor-main"
    private static let positionPrefix = "NSStatusItem Preferred Position "
    private static let visiblePrefix = "NSStatusItem VisibleCC "
    private static let preparedKey = "didPrepareStatusItemPlacementV2"

    static func prepare(defaults: UserDefaults) {
        guard !defaults.bool(forKey: preparedKey) else { return }
        let positionKey = positionPrefix + autosaveName
        if let value = defaults.object(forKey: positionKey) as? NSNumber {
            let maximum = NSScreen.screens.map { $0.frame.maxX }.max() ?? 0
            if value.doubleValue <= 0 || (maximum > 0 && value.doubleValue > maximum + 512) {
                defaults.removeObject(forKey: positionKey)
            }
        } else {
            defaults.set(700.0, forKey: positionKey)
        }
        let visibleKey = visiblePrefix + autosaveName
        if (defaults.object(forKey: visibleKey) as? NSNumber)?.boolValue == false {
            defaults.removeObject(forKey: visibleKey)
        }
        defaults.set(true, forKey: preparedKey)
    }
}

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
        LegacyDefaultsMigration.runIfNeeded()
        StatusItemPlacement.prepare(defaults: .standard)
        // Let AppKit finish constructing the menu bar before creating the
        // status item; creating it during applicationDidFinishLaunching can
        // leave its window at y=-6 instead of inside the menu bar.
        DispatchQueue.main.async { [weak self] in
            self?.statusBarController = StatusBarController(store: MonitorStore())
        }
    }
}

@MainActor
enum CodexHookSetupUI {
    private static var isPresenting = false

    static func presentIfNeeded(store: MonitorStore, alwaysShowStatus: Bool = false) async {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        await store.reloadHookSetupStatus()
        if store.hookSetupStatus == .active {
            guard alwaysShowStatus else { return }
            showResult(
                title: "小狗任务动画已启用",
                message: "Hooks 已安装并获得授权。任务开始和结束时，小狗会自动切换状态。",
                style: .informational
            )
            return
        }

        NSApplication.shared.activate()
        let confirmation = NSAlert()
        confirmation.messageText = "启用小狗任务动画？"
        confirmation.informativeText = "Codex Monitor 将安装完整生命周期 Hooks，并同时完成 Codex 授权。Hooks 只记录会话标识、轮次标识、运行状态和更新时间；不会保存提示词、文件内容、命令输出或回复。"
        confirmation.alertStyle = .informational
        confirmation.addButton(withTitle: "安装并授权")
        confirmation.addButton(withTitle: "暂不")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            try await store.installCodexHooks()
            showResult(
                title: "Hooks 已启用",
                message: "安装和授权已经完成，不需要再打开 CLI。若 Codex Desktop 当前正在运行，重新打开一次后即可加载新的 Hooks。",
                style: .informational
            )
        } catch {
            showResult(
                title: "Hooks 启用失败",
                message: errorMessage(for: error),
                style: .warning
            )
        }
    }

    private static func showResult(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private static func errorMessage(for error: Error) -> String {
        switch error {
        case CodexHookInstaller.InstallError.codexNotFound:
            "没有找到 Codex Desktop 或 Codex CLI。请先安装并打开 Codex，然后重试。"
        case CodexHookInstaller.InstallError.invalidExistingHooks:
            "现有的 ~/.codex/hooks.json 无法解析，因此没有覆盖它。请检查该文件后重试。"
        case CodexHookInstaller.InstallError.missingBundledHelper:
            "应用中缺少 Hooks 辅助程序，请重新安装 Codex Monitor。"
        case CodexHookInstaller.InstallError.hooksNotDiscovered,
             CodexHookInstaller.InstallError.trustWasNotSaved:
            "Hooks 已写入，但 Codex 没有完成授权。请重新打开 Codex Monitor 后再试。"
        case CodexHookInstaller.InstallError.appServerUnavailable,
             CodexHookInstaller.InstallError.appServerTimedOut,
             CodexHookInstaller.InstallError.invalidAppServerResponse,
             CodexHookInstaller.InstallError.appServerError(_):
            "暂时无法连接 Codex 的配置服务。请确认 Codex 已正确安装，然后重试。"
        default:
            "没有修改已有的其他 Hooks。请确认 Codex Monitor 位于 Applications 文件夹后重试。"
        }
    }
}

@MainActor
private final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: MonitorStore
    private var statusItem: NSStatusItem
    private let popover = NSPopover()
    private var statusHostingView: PassthroughHostingView<StatusLabel>?
    private var lastPopoverCloseAt = Date.distantPast

    init(store: MonitorStore) {
        self.store = store
        StatusItemPlacement.prepare(defaults: .standard)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = StatusItemPlacement.autosaveName
        self.statusItem.isVisible = true
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
            rootView: StatusLabel(
                snapshot: store.snapshot,
                dogState: store.dogActivityState
            )
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
            _ = store.dogActivityState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusContent()
                self?.observeStatusContent()
            }
        }
    }

    private func updateStatusContent() {
        statusHostingView?.rootView = StatusLabel(
            snapshot: store.snapshot,
            dogState: store.dogActivityState
        )
        let quotaText = store.snapshot.statusWindow.map { "\($0.remainingPercent)%" } ?? "—"
        let font = NSFont.menuBarFont(ofSize: 0)
        let textWidth = ceil((quotaText as NSString).size(withAttributes: [.font: font]).width)
        let iconWidth: CGFloat = 28
        statusItem.length = iconWidth + 5 + textWidth + 8
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
