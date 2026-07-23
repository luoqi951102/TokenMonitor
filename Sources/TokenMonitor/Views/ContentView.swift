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
    @State private var hoveringModelID: String? = nil

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
                        Text(t.label).font(Theme.Typography.body.weight(tab == t ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(tab == t ? Theme.brand.opacity(0.12) : .clear)
                    .foregroundStyle(tab == t ? Theme.brand : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(3)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            kpiRow
            // streak（跨 range 不变，永远显示当前状态）
            StreakCard(streak: viewModel.streak)
            topModelsCard
            // 项目维度 Top 5
            ProjectRankingView(projects: viewModel.topProjects(5))
            trendCard
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("Token Monitor")
                    .font(Theme.Typography.title)
                Text(viewModel.syncStatusText)
                    .font(Theme.Typography.caption)
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
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

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
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
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
                .font(Theme.Typography.body.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Theme.brand.opacity(0.12) : .clear)
                .foregroundStyle(isActive ? Theme.brand : .primary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - KPI Row
    //
    // 三栏 KPI 合并为单一卡片容器，用 hairline Divider 分割。
    // 比「三个独立卡片拼排」更连贯，留白更通透，跟 macOS Tahoe 系统工具风一致。

    private var kpiRow: some View {
        HStack(spacing: 0) {
            kpi(label: "总 Token", value: formatTokens(viewModel.totalTokens), tokens: viewModel.totalTokens)
            Divider().frame(height: 32).opacity(0.25)
            kpi(label: "消息数", value: formatNumber(viewModel.totalMsgs), tokens: viewModel.totalMsgs)
            Divider().frame(height: 32).opacity(0.25)
            kpi(label: "工具调用", value: formatNumber(viewModel.totalToolCalls), tokens: viewModel.totalToolCalls)
        }
        .padding(.vertical, 10)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func kpi(label: String, value: String, tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.Typography.metric)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: Double(tokens)))
                .animation(.easeOut(duration: 0.3), value: tokens)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    // MARK: - Top Models

    private var topModelsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top 模型")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.models.count) 个模型 · 切到「模型」tab 看全部")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if viewModel.models.isEmpty {
                Text(viewModel.hasDB ? "区间内无数据" : "未连接到 ccusage.db")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                let maxTotal = viewModel.models.first?.totalTokens ?? 1
                // 总览只展示 Top 8，避免面板溢出；完整列表在「模型」tab
                ForEach(viewModel.topModels(8)) { usage in
                    modelBar(usage, maxTotal: maxTotal)
                }
            }
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func modelBar(_ usage: ModelUsage, maxTotal: Int) -> some View {
        let pct = maxTotal > 0 ? Double(usage.totalTokens) / Double(maxTotal) : 0
        let providerName = providerDisplayName(usage.provider, model: usage.model)
        // 次行：provider 后追加来源后缀（Claude Code / ZCode），避免同 provider 不同 source 歧义
        // 例：浙算MaaS 同时出现在 Claude Code 和 ZCode，单看 "浙算MaaS" 无法辨认
        // 用闭包生成 Text concat：provider 名 + 弱色 source 后缀，渲染一体但颜色分层
        // 用短标签 CC/ZC 节省宽度（与浮窗一致）
        let sourceLabel = UsageSource(rawValue: usage.source)?.shortLabel ?? usage.source
        let providerFull = providerName.isEmpty
            ? usage.model
            : "\(usage.model) · \(providerName)"
        return HStack(spacing: 8) {
            Circle()
                .fill(Theme.modelColor(usage.model + usage.provider))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(usage.model)
                    .font(Theme.Typography.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 次行：用 Text + Text concat，provider 用 .tertiary，source 后缀更弱显
                // 让 source 不会喧宾夺主，又能明确区分来源通道。
                (
                    Text(providerName.isEmpty ? "" : providerName)
                    + Text(providerName.isEmpty ? sourceLabel : " · \(sourceLabel)")
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                    RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                        .fill(Theme.modelColor(usage.model + usage.provider).opacity(0.85))
                        .frame(width: max(4, geo.size.width * pct))
                }
            }
            .frame(height: 8)
            Text(formatTokens(usage.totalTokens))
                .font(Theme.Typography.captionMonospaced)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(height: 26)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hoveringModelID == usage.id ? Color.primary.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hoveringModelID = $0 ? usage.id : nil }
        .help(providerFull)
        .animation(.easeInOut(duration: 0.15), value: hoveringModelID)
    }

    // MARK: - Trend
    //
    // 趋势图两套渲染：
    //   - 密度 ≤ 14：传统柱状图（每天一根柱，柱顶 + 日期标签可读）
    //   - 密度 > 14：sparkline（1px hairline Path，末端 accent dot 标最新点）
    // sparkline 跟 Apple 系统工具的 trend indicator 一致，更轻、更现代。

    private var trendCard: some View {
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
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.rangeLabel)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if displayData.isEmpty {
                Text("区间内无数据")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if displayData.count <= 14 {
                // 稀疏场景仍用柱状图（每柱留有数字 + 日期标签的空间）
                let maxTokens = displayData.map(\.tokens).max() ?? 1
                let spacing: CGFloat = displayData.count > 10 ? 3 : 5
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(displayData) { d in
                        VStack(spacing: 2) {
                            Text(formatTokens(d.tokens))
                                .font(Theme.Typography.captionMonospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                                .fill(Theme.chartBar)
                                .frame(height: barHeight(d.tokens, max: maxTokens))
                            Text(String(d.date.suffix(5)))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 90)
            } else {
                // 密集场景用 sparkline（hairline + 末端 accent dot）
                trendSparkline(displayData)
                    .frame(height: 56)
            }
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// 1px hairline Path sparkline，跟随容器宽度自适应。
    /// 末端（最新数据点）叠一个 accent color 点，强化"现在"的视觉锚点。
    private func trendSparkline(_ data: [DailyTotal]) -> some View {
        let maxTokens = max(data.map(\.tokens).max() ?? 1, 1)
        let last = data.last?.tokens ?? 0

        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let stepX = data.count > 1 ? w / CGFloat(data.count - 1) : w
            let points = data.enumerated().map { (i, d) -> CGPoint in
                let x = CGFloat(i) * stepX
                let y = h - (CGFloat(d.tokens) / CGFloat(maxTokens)) * (h - 4) - 2
                return CGPoint(x: x, y: y)
            }

            ZStack {
                // hairline path
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() {
                        p.addLine(to: pt)
                    }
                }
                .stroke(
                    Theme.brand.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                )

                // 末端 accent dot（5pt 圆点，1pt 宽白色 ring 跟线分离）
                if let lastPt = points.last {
                    Circle()
                        .fill(Theme.brand)
                        .frame(width: 5, height: 5)
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                        )
                        .position(lastPt)
                }

                // 末端 token 数字（在点上方）
                if let lastPt = points.last {
                    Text(formatTokens(last))
                        .font(Theme.Typography.captionMonospaced)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.cardBackground(for: colorScheme).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .position(x: min(lastPt.x, w - 36), y: lastPt.y - 10)
                }
            }
        }
    }

    private func barHeight(_ v: Int, max m: Int) -> CGFloat {
        guard m > 0 else { return 4 }
        return max(4, CGFloat(v) / CGFloat(m) * 60)
    }
}
