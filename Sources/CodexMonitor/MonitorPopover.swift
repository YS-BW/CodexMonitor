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

    var body: some View {
        ReorderableVStack(availableModules, onMove: moveModule) { module, isDragged in
            ModuleSurface {
                moduleContent(for: module)
            }
                .padding(.vertical, 6)
                .opacity(isDragged ? 0.92 : 1)
                .scaleEffect(isDragged ? 1.01 : 1)
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
                UsageCard(
                    window: current,
                    isRefreshing: store.isRefreshing,
                    onRefresh: { Task { await store.refresh() } }
                )
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
            case .currentUsage: store.snapshot.current != nil
            case .weeklyUsage: store.snapshot.weekly != nil
            case .recentSessions: true
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
    var isRefreshing = false
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.title).fontWeight(.medium)
                Spacer()
                Text("剩余 \(window.remainingPercent)%").fontWeight(.medium)
                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .disabled(isRefreshing)
                    .accessibilityLabel("刷新额度与会话")
                }
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
