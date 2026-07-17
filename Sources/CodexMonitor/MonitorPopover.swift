import SwiftUI
import Charts
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
    @AppStorage("showsTotalTokens") private var showsTotalTokens = true
    @AppStorage("showsTokenTrend") private var showsTokenTrend = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 5
    @AppStorage("cliTerminal") private var cliTerminal = CLITerminal.terminal.rawValue

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
                    showsTotalTokens: $showsTotalTokens,
                    showsTokenTrend: $showsTokenTrend,
                    cliTerminal: $cliTerminal,
                    refreshIntervalMinutes: $refreshIntervalMinutes
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                .zIndex(0)
            }

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 0) {
                BottomActionButton(symbol: "arrow.clockwise", title: "刷新", alignment: .leading) {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)

                BottomActionButton(symbol: "gearshape", title: "设置", alignment: .center) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                        isSettingsExpanded.toggle()
                    }
                }

                BottomActionButton(symbol: "power", title: "关闭", alignment: .trailing) {
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
        case .totalTokens:
            TotalTokensModule(summary: store.tokenSummary)
        case .tokenTrend:
            TokenTrendModule(trend: store.tokenTrend)
        case .recentSessions:
            RecentSessionsModule(
                sessions: store.sessions,
                error: store.sessionReadError,
                cliTerminal: CLITerminal(rawValue: cliTerminal) ?? .terminal
            )
        }
    }

    private var availableModules: [DashboardModule] {
        store.moduleOrder.filter { module in
            switch module {
            case .currentUsage: showsFiveHourUsage && store.snapshot.current != nil
            case .weeklyUsage: showsWeeklyUsage && store.snapshot.weekly != nil
            case .totalTokens: showsTotalTokens
            case .tokenTrend: showsTokenTrend
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

enum TrackpadHaptics {
    static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

private struct ModuleSurface<Content: View>: View {
    let isDragging: Bool
    let showsDivider: Bool
    @ViewBuilder let content: Content
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(WeatherPalette.highlight(for: colorScheme).opacity(isHovered || isDragging ? 1 : 0))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            if showsDivider {
                Divider()
                    .padding(.horizontal, 12)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.16), value: isHovered || isDragging)
    }
}

private enum WeatherPalette {
    static func highlight(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            Color(red: 52.0 / 255.0, green: 54.0 / 255.0, blue: 58.0 / 255.0)
        default:
            Color(red: 231.0 / 255.0, green: 232.0 / 255.0, blue: 234.0 / 255.0)
        }
    }

    static func actionBackground(for colorScheme: ColorScheme) -> Color {
        highlight(for: colorScheme).opacity(colorScheme == .dark ? 1 : 0.78)
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
                .tint(progressColor)
                .padding(.vertical, 2)
            HStack(spacing: 3) {
                Text(window.resetsAt, style: .relative)
                Text("后重置")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var progressColor: Color {
        switch window.remainingPercent {
        case 81...100: .blue
        case 40...80: .yellow
        default: .red
        }
    }
}

private struct RecentSessionsModule: View {
    let sessions: [CodexSession]
    let error: String?
    let cliTerminal: CLITerminal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近会话").font(.headline.weight(.semibold))
                Spacer()
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
                        SessionRow(session: session) {
                            SessionLauncher.open(session, cliTerminal: cliTerminal)
                        }
                        if index < sessions.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct TotalTokensModule: View {
    let summary: TokenSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("总 Token 消耗")
                    .font(.headline.weight(.semibold))
                Text("本机本地会话累计")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(summary.totalTokens.tokenDisplay)
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
        }
    }
}

private struct TokenTrendModule: View {
    let trend: TokenTrend
    @State private var selectedDay: TokenTrend.Day?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token 消耗趋势")
                        .font(.headline.weight(.semibold))
                    Text(selectedDateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(selectedTokenLabel)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.rounded)
            }

            Chart(trend.days) { day in
                AreaMark(
                    x: .value("日期", day.date),
                    y: .value("Token", day.tokens)
                )
                .foregroundStyle(.blue.opacity(0.14))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("日期", day.date),
                    y: .value("Token", day.tokens)
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("日期", day.date),
                    y: .value("Token", day.tokens)
                )
                .foregroundStyle(.blue)
                .symbolSize(selectedDay?.id == day.id ? 42 : 16)

                if selectedDay?.id == day.id {
                    RuleMark(x: .value("日期", day.date))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxis {
                AxisMarks(values: trend.days.map(\.date)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .font(.caption2)
                }
            }
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let plotOrigin = geometry[plotFrame].origin
                                let chartX = location.x - plotOrigin.x
                                let chartY = location.y - plotOrigin.y
                                let hitRadius: CGFloat = 9
                                let hit = trend.days.compactMap { day -> (day: TokenTrend.Day, distance: CGFloat)? in
                                    guard let pointX = proxy.position(forX: day.date),
                                          let pointY = proxy.position(forY: day.tokens)
                                    else { return nil }
                                    return (day, hypot(pointX - chartX, pointY - chartY))
                                }
                                .min { $0.distance < $1.distance }
                                .flatMap { $0.distance <= hitRadius ? $0.day : nil }

                                if hit?.id != selectedDay?.id, hit != nil {
                                    TrackpadHaptics.alignment()
                                }
                                selectedDay = hit
                            case .ended:
                                selectedDay = nil
                            }
                        }
                }
            }
            .frame(height: 96)
            .accessibilityLabel("最近 7 天 Token 消耗趋势")

            HStack {
                Label("日均 \(average.tokenDisplay)", systemImage: "chart.bar")
                Spacer()
                Label("最高 \(peak.tokenDisplay)", systemImage: "arrow.up.right")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var average: Int {
        guard !trend.days.isEmpty else { return 0 }
        return trend.days.map(\.tokens).reduce(0, +) / trend.days.count
    }

    private var peak: Int { trend.days.map(\.tokens).max() ?? 0 }

    private var selectedDateLabel: String {
        guard let selectedDay else { return "最近 7 天 · 移动鼠标查看" }
        return selectedDay.date.formatted(.dateTime.month().day().weekday(.wide))
    }

    private var selectedTokenLabel: String {
        guard let selectedDay else { return "近 7 天" }
        return "\(selectedDay.tokens.tokenDisplay) tokens"
    }
}

private struct BottomActionButton: View {
    let symbol: String
    let title: String
    let alignment: Alignment
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(WeatherPalette.actionBackground(for: colorScheme)))
                .frame(maxWidth: .infinity, alignment: alignment)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(isHovered ? 0.78 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(title)
    }
}

private struct SettingsPanel: View {
    @Binding var showsRecentSessions: Bool
    @Binding var showsWeeklyUsage: Bool
    @Binding var showsFiveHourUsage: Bool
    @Binding var showsTotalTokens: Bool
    @Binding var showsTokenTrend: Bool
    @Binding var cliTerminal: String
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
                SettingPill(title: "总 Token", symbol: "sum", isSelected: showsTotalTokens) {
                    showsTotalTokens.toggle()
                }
                SettingPill(title: "Token 趋势", symbol: "chart.xyaxis.line", isSelected: showsTokenTrend) {
                    showsTokenTrend.toggle()
                }
                SettingPill(
                    title: "刷新 \(refreshIntervalLabel)",
                    symbol: "arrow.triangle.2.circlepath",
                    isSelected: true
                ) {
                    refreshIntervalMinutes = nextRefreshInterval
                }
            }

            Text("CLI 会话打开方式")
                .font(.footnote.weight(.medium))

            HStack(spacing: 8) {
                SettingPill(
                    title: CLITerminal.terminal.title,
                    symbol: "terminal",
                    isSelected: cliTerminal == CLITerminal.terminal.rawValue
                ) {
                    cliTerminal = CLITerminal.terminal.rawValue
                }
                SettingPill(
                    title: CLITerminal.ghostty.title,
                    symbol: "ghost",
                    isSelected: cliTerminal == CLITerminal.ghostty.rawValue
                ) {
                    cliTerminal = CLITerminal.ghostty.rawValue
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
    @Environment(\.colorScheme) private var colorScheme

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
        .background(Capsule().fill(WeatherPalette.highlight(for: colorScheme).opacity(isHovered ? 1 : 0)))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(title)
    }
}

private struct SessionRow: View {
    let session: CodexSession
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(session.isActive ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 5) {
                Label(session.source.rawValue, systemImage: session.source.symbolName)
                Text("·")
                Text(session.tokensUsed.tokenDisplay + " tokens")
                if let goalStatus = session.goalStatus {
                    Text("·")
                    Text(goalStatus.label)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityAddTraits(.isButton)
    }
}

private extension CodexSession.Source {
    var symbolName: String {
        switch self {
        case .desktopApp: "desktopcomputer"
        case .cli: "terminal"
        case .ide: "chevron.left.forwardslash.chevron.right"
        case .unknown: "sparkles"
        }
    }
}

private extension Int {
    var tokenDisplay: String {
        switch self {
        case 1_000_000...:
            String(format: "%.1fM", Double(self) / 1_000_000)
        case 1_000...:
            String(format: "%.1fk", Double(self) / 1_000)
        default:
            "\(self)"
        }
    }
}
