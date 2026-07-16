import AppKit
import SwiftUI

@main
struct CodexMonitorApp: App {
    @State private var monitorStore = MonitorStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover(store: monitorStore)
        } label: {
            StatusLabel(snapshot: monitorStore.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}
