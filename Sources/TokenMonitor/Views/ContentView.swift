import SwiftUI

// MARK: - Main Panel
//
// M3 将实现：range + source 切换、KPI 行、Top-N 模型横条、7 天趋势。
// 这里先给出完整可用的版本，后续里程碑可在该结构上扩展。

struct ContentView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable {
        case overview
        case models
        case tools

        var label: String {
            switch self {
            case .overview: return "总览"
            case .models: return "模型"
            case .tools: return "工具"
            }
        }

        var icon: String {
            switch self {
            case .overview: return "chart.bar.xaxis"
            case .models: return "scalemass"
            case .tools: return "wrench.and.screwdriver"
            }
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous)
                        .strokeBorder(Theme.panelBorder(for: colorScheme), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 10) {
                header
                tabBar
                filterBar

                ScrollView(.vertical, showsIndicators: false) {
                    switch tab {
                    case .overview:
                        overviewTab
                    case .models:
                        ModelComparisonView(viewModel: viewModel)
                    case .tools:
                        ToolCallView(viewModel: viewModel)
                    }
                }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous))
        .shadow(color: Theme.panelShadow(for: colorScheme), radius: 20, x: 0, y: 12)
        .frame(width: Theme.panelWidth, height: Theme.panelDashboardHeight)
        .background(Color.clear)
        .onChange(of: viewModel.range) { _, _ in viewModel.pushWidgetSnapshot() }
        .onChange(of: viewModel.source) { _, _ in viewModel.pushWidgetSnapshot() }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button(action: { tab = t }) {
                    HStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 10))
                        Text(t.label).font(.caption.weight(tab == t ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(tab == t ? Theme.brand.opacity(0.18) : .clear)
                    .foregroundStyle(tab == t ? Theme.brand : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(3)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            kpiRow
            topModelsCard
            trendCard
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text("Token Monitor")
                    .font(.title3.weight(.semibold))
                Text(viewModel.syncStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { Task { await viewModel.manualSync() } }) {
                if viewModel.syncRunner.isSyncing {
                    ProgressView().scaleEffect(0.65).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .help("立即同步")
            .disabled(viewModel.syncRunner.isSyncing)

            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .help("刷新视图")

            Button(action: { FloatingWidgetWindow.shared.toggle(viewModel: viewModel) }) {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .help("显示/隐藏桌面小窗")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("设置")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    // MARK: - Range + Source Filter

    private var filterBar: some View {
        HStack(spacing: 6) {
            // Range 分段
            HStack(spacing: 2) {
                ForEach(UsageRange.allCases, id: \.self) { r in
                    filterChip(r.displayName, isActive: viewModel.range == r) {
                        viewModel.range = r
                    }
                }
            }
            .padding(3)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            // Source 分段
            HStack(spacing: 2) {
                ForEach(["all", "claude", "zcode"], id: \.self) { src in
                    filterChip(sourceLabel(src), isActive: viewModel.source == src) {
                        viewModel.source = src
                    }
                }
            }
            .padding(3)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "all": return "全部"
        case "claude": return "Claude"
        case "zcode": return "ZCode"
        default: return s
        }
    }

    private func filterChip(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Theme.brand.opacity(0.18) : .clear)
                .foregroundStyle(isActive ? Theme.brand : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - KPI Row

    private var kpiRow: some View {
        HStack(spacing: 8) {
            kpi(label: "总 Token", value: formatTokens(viewModel.totalTokens), color: Theme.brand)
            kpi(label: "消息数", value: formatNumber(viewModel.totalMsgs), color: Theme.tokenCacheWrite)
            kpi(label: "工具调用", value: formatNumber(viewModel.totalToolCalls), color: Theme.tokenCacheRead)
        }
    }

    private func kpi(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Top Models

    private var topModelsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top 模型")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.models.count) 个模型 · 切到「模型」tab 看全部")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if viewModel.models.isEmpty {
                Text(viewModel.hasDB ? "区间内无数据" : "未连接到 ccusage.db")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                let maxTotal = viewModel.models.first?.totalTokens ?? 1
                // 总览只展示 Top 6，避免面板溢出；完整列表在「模型」tab
                ForEach(viewModel.topModels(6)) { usage in
                    modelBar(usage, maxTotal: maxTotal)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func modelBar(_ usage: ModelUsage, maxTotal: Int) -> some View {
        let pct = maxTotal > 0 ? Double(usage.totalTokens) / Double(maxTotal) : 0
        return HStack(spacing: 8) {
            Circle()
                .fill(Theme.modelColor(usage.model))
                .frame(width: 8, height: 8)
            Text(usage.model)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 108, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary.opacity(0.4))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.modelColor(usage.model).opacity(0.85))
                        .frame(width: max(4, geo.size.width * pct))
                }
            }
            .frame(height: 10)
            Text(formatTokens(usage.totalTokens))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(height: 20)
    }

    // MARK: - Trend

    private var trendCard: some View {
        // range=all 时区间可能跨数月，按天展示柱太密，最多展示最近 30 天
        let displayData: [DailyTotal] = {
            let cap: Int
            switch viewModel.range {
            case .today, .week: cap = 14
            case .month: cap = 31
            case .all: cap = 30
            }
            return Array(viewModel.daily.suffix(cap))
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("趋势")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.rangeLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if displayData.isEmpty {
                Text("区间内无数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                let maxTokens = displayData.map(\.tokens).max() ?? 1
                // 柱间距随密度自适应：柱少时间距大、柱多时紧凑
                let spacing: CGFloat = displayData.count > 20 ? 1.5 : (displayData.count > 10 ? 3 : 5)
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(displayData) { d in
                        VStack(spacing: 2) {
                            // 柱多时只显示部分柱顶数字，避免拥挤
                            if displayData.count <= 14 {
                                Text(formatTokens(d.tokens))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.chartBar)
                                .frame(height: barHeight(d.tokens, max: maxTokens))
                            // 柱多时只显示首尾日期
                            if displayData.count <= 14 {
                                Text(String(d.date.suffix(5)))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: displayData.count > 14 ? 60 : 90)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func barHeight(_ v: Int, max m: Int) -> CGFloat {
        guard m > 0 else { return 4 }
        return max(4, CGFloat(v) / CGFloat(m) * 60)
    }
}
