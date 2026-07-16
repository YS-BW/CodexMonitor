import SwiftUI
import Reorderable
import AppKit

struct StatusLabel: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
            Text(snapshot.statusWindow.map { "\($0.remainingPercent)%" } ?? "—")
        }
        .accessibilityLabel(snapshot.statusWindow.map { "Codex 额度剩余 \($0.remainingPercent)%" } ?? "Codex 额度暂不可用")
    }
}

struct MonitorPopover: View {
    let store: MonitorStore
    @State private var isSettingsExpanded = false
    @Namespace private var glassNamespace
    @AppStorage("showsRecentSessions") private var showsRecentSessions = true
    @AppStorage("showsWeeklyUsage") private var showsWeeklyUsage = true
    @AppStorage("showsFiveHourUsage") private var showsFiveHourUsage = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 5

    var body: some View {
        VStack(spacing: 4) {
            ReorderableVStack(availableModules, onMove: moveModule) { module, isDragged in
                ModuleSurface {
                    moduleContent(for: module)
                }
                    .padding(.vertical, 6)
                    .opacity(isDragged ? 0.92 : 1)
                    .scaleEffect(isDragged ? 1.01 : 1)
            }

            if isSettingsExpanded {
                SettingsPanel(
                    showsRecentSessions: $showsRecentSessions,
                    showsWeeklyUsage: $showsWeeklyUsage,
                    showsFiveHourUsage: $showsFiveHourUsage,
                    refreshIntervalMinutes: $refreshIntervalMinutes
                )
                .glassEffectID("settings-panel", in: glassNamespace)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                .zIndex(0)
            }

            HStack(spacing: 10) {
                BottomActionButton(symbol: "arrow.clockwise", label: "刷新额度与会话") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)

                Spacer()

                SettingsToggleButton(isExpanded: isSettingsExpanded, namespace: glassNamespace) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                        isSettingsExpanded.toggle()
                    }
                }

                Spacer()

                BottomActionButton(symbol: "power", label: "退出 Codex Monitor") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.top, 4)
            .zIndex(1)
        }
        .disableSensoryFeedback()
        .padding(10)
        .frame(width: 330)
    }

    @ViewBuilder
    private func moduleContent(for module: DashboardModule) -> some View {
        switch module {
        case .currentUsage:
            if let current = store.snapshot.current {
                UsageCard(window: current)
            }
        case .weeklyUsage:
            if let weekly = store.snapshot.weekly {
                UsageCard(window: weekly)
            }
        case .recentSessions:
            RecentSessionsModule(sessions: store.sessions, error: store.sessionReadError)
        }
    }

    private var availableModules: [DashboardModule] {
        store.moduleOrder.filter { module in
            switch module {
            case .currentUsage: showsFiveHourUsage && store.snapshot.current != nil
            case .weeklyUsage: showsWeeklyUsage && store.snapshot.weekly != nil
            case .recentSessions: showsRecentSessions
            }
        }
    }

    private func moveModule(from: Int, to: Int) {
        var reorderedVisibleModules = availableModules
        let destination = to > from ? to + 1 : to
        reorderedVisibleModules.move(
            fromOffsets: IndexSet(integer: from),
            toOffset: destination
        )

        var iterator = reorderedVisibleModules.makeIterator()
        TrackpadHaptics.alignment()
        withAnimation(.snappy) {
            store.moduleOrder = store.moduleOrder.map { module in
                reorderedVisibleModules.contains(module) ? iterator.next()! : module
            }
        }
    }
}

private enum TrackpadHaptics {
    static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

private struct ModuleSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct UsageCard: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.title).fontWeight(.medium)
                Spacer()
                Text("剩余 \(window.remainingPercent)%").fontWeight(.medium)
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .progressViewStyle(.linear)
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .glassEffect(.regular, in: Capsule())
            HStack(spacing: 3) {
                Text(window.resetsAt, style: .relative)
                Text("后重置")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct RecentSessionsModule: View {
    let sessions: [CodexSession]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近会话").font(.headline)
                Spacer()
                Text("\(sessions.count) 个").foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if sessions.isEmpty {
                Text("尚未发现最近 7 天的本地 Codex 会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
            } else {
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 8) {
                        ForEach(sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                }
            }
        }
    }
}

private struct BottomActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Circle())
        .accessibilityLabel(label)
    }
}

private struct SettingsToggleButton: View {
    let isExpanded: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("设置", systemImage: "gearshape")
                .font(.caption.weight(.medium))
                .frame(width: 72, height: 32)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Capsule())
        .glassEffectID("settings-toggle", in: namespace)
        .accessibilityLabel(isExpanded ? "收起设置" : "展开设置")
    }
}

private struct SettingsPanel: View {
    @Binding var showsRecentSessions: Bool
    @Binding var showsWeeklyUsage: Bool
    @Binding var showsFiveHourUsage: Bool
    @Binding var refreshIntervalMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("显示模块")
                .font(.subheadline.weight(.medium))

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                SettingPill(title: "最近会话", symbol: "bubble.left.and.bubble.right", isSelected: showsRecentSessions) {
                    showsRecentSessions.toggle()
                }
                SettingPill(title: "本周额度", symbol: "calendar", isSelected: showsWeeklyUsage) {
                    showsWeeklyUsage.toggle()
                }
                SettingPill(title: "5h 额度", symbol: "clock", isSelected: showsFiveHourUsage) {
                    showsFiveHourUsage.toggle()
                }
                SettingPill(
                    title: "刷新 \(refreshIntervalLabel)",
                    symbol: "arrow.triangle.2.circlepath",
                    isSelected: true
                ) {
                    refreshIntervalMinutes = nextRefreshInterval
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }

    private var refreshIntervalLabel: String {
        refreshIntervalMinutes == 0 ? "手动" : "\(refreshIntervalMinutes) 分钟"
    }

    private var nextRefreshInterval: Int {
        switch refreshIntervalMinutes {
        case 0: 5
        case 5: 15
        case 15: 30
        default: 0
        }
    }

}

private struct SettingPill: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : symbol)
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Capsule())
        .accessibilityLabel(title)
    }
}

private struct SessionRow: View {
    let session: CodexSession

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(session.isActive ? Color.green : Color.secondary).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                Text(session.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.isActive ? "活跃" : "空闲")
                Text(session.lastActivityAt.formatted(.relative(presentation: .named)))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }
}
