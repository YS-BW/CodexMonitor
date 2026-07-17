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
    @AppStorage("showsRecentSessions") private var showsRecentSessions = true
    @AppStorage("showsWeeklyUsage") private var showsWeeklyUsage = true
    @AppStorage("showsFiveHourUsage") private var showsFiveHourUsage = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 5

    var body: some View {
        VStack(spacing: 0) {
            ReorderableVStack(availableModules, onMove: moveModule) { module, isDragged in
                ModuleSurface(
                    isDragging: isDragged,
                    showsDivider: module != availableModules.last
                ) {
                    moduleContent(for: module)
                }
                    .padding(.vertical, 0)
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
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                .zIndex(0)
            }

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 0) {
                BottomActionButton(symbol: "arrow.clockwise", title: "刷新") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)

                Spacer()

                BottomActionButton(symbol: "gearshape", title: "设置") {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                        isSettingsExpanded.toggle()
                    }
                }

                Spacer()

                BottomActionButton(symbol: "power", title: "关闭") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .zIndex(1)
        }
        .disableSensoryFeedback()
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
    let isDragging: Bool
    let showsDivider: Bool
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if showsDivider {
                Divider()
                    .padding(.horizontal, 12)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        Color(
                            red: 231.0 / 255.0,
                            green: 232.0 / 255.0,
                            blue: 234.0 / 255.0,
                            opacity: isHovered || isDragging ? 1 : 0
                        )
                    )
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.16), value: isHovered || isDragging)
    }
}

private struct UsageCard: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.title)
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("剩余 \(window.remainingPercent)%")
                    .font(.headline.weight(.semibold))
                    .fontDesign(.rounded)
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .progressViewStyle(.linear)
                .tint(.blue)
                .padding(.vertical, 2)
            HStack(spacing: 3) {
                Text(window.resetsAt, style: .relative)
                Text("后重置")
            }
            .font(.footnote)
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
                Text("最近会话").font(.headline.weight(.semibold))
                Spacer()
                Text("\(sessions.count) 个")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if sessions.isEmpty {
                Text("尚未发现最近 7 天的本地 Codex 会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(session: session)
                        if index < sessions.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct BottomActionButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .frame(height: 26)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(isHovered ? 0.08 : 0)))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(title)
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
                .font(.footnote.weight(.medium))

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
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : symbol)
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(.primary.opacity(isHovered ? 0.08 : 0)))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(title)
    }
}

private struct SessionRow: View {
    let session: CodexSession

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(session.isActive ? Color.green : Color.secondary).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(session.preview)
                    .font(.caption2)
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
        .padding(.vertical, 9)
    }
}
