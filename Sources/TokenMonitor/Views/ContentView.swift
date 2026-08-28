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
    @ObservedObject private var skinMgr = SkinManager.shared
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
                // tab 切换时内容整体上浮淡入（配合 tabBar 的 withAnimation）
                .id(tab)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                Button(action: {
                    // tab 切换带过渡动画：内容整体上浮淡入
                    withAnimation(.easeOut(duration: 0.22)) { tab = t }
                }) {
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
                .staggerAppear(tab: tab, index: 0)
            // streak（跨 range 不变，永远显示当前状态）
            StreakCard(streak: viewModel.streak)
                .staggerAppear(tab: tab, index: 1)
            topModelsCard
                .staggerAppear(tab: tab, index: 2)
            // 项目维度 Top 5
            ProjectRankingView(projects: viewModel.topProjects(5))
                .staggerAppear(tab: tab, index: 3)
            // 今日时段分布（仅今日且有数据时显示）
            if viewModel.range == .today && !viewModel.hourly.isEmpty {
                hourlyCard
                    .staggerAppear(tab: tab, index: 4)
            }
            trendCard
                .staggerAppear(tab: tab, index: 5)
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

            // 皮肤切换：Menu 弹三套风格
            Menu {
                ForEach(Skin.allCases) { s in
                    Button(action: { SkinManager.shared.skin = s }) {
                        if s == SkinManager.shared.skin {
                            Label(s.displayName, systemImage: "checkmark")
                        } else {
                            Text(s.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: skinMgr.skin.icon)
                    .foregroundStyle(Theme.brand)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("切换皮肤")

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
                // 刷新后大数字短暂放大 spring 一下，跟浮窗同款 refreshPulse 信号
                .scaleEffect(viewModel.refreshPulse ? 1.06 : 1.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.55), value: viewModel.refreshPulse)
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
                // 环形占比图 + 精简 Top 6 列表（并排），占比一目了然
                let top6 = Array(viewModel.models.prefix(6))
                let totalTokens = top6.reduce(0) { $0 + $1.totalTokens }
                HStack(alignment: .center, spacing: 14) {
                    // 环形占比图：Top 6 模型按 token 占比
                    DonutChart(
                        segments: top6.map { usage in
                            DonutSegment(
                                color: Theme.modelColor(usage.model + usage.provider),
                                value: Double(usage.totalTokens)
                            )
                        },
                        ringWidth: 12,
                        centerTitle: "Top \(top6.count)",
                        centerValue: formatTokens(totalTokens)
                    )
                    .frame(width: 108, height: 108)

                    // 右侧：Top 6 排名（紧凑版，带占比百分比）
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(top6.enumerated()), id: \.element.id) { idx, usage in
                            HStack(spacing: 6) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 12, alignment: .center)
                                Circle()
                                    .fill(Theme.modelColor(usage.model + usage.provider))
                                    .frame(width: 6, height: 6)
                                Text(usage.model)
                                    .font(Theme.Typography.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(Int(Double(usage.totalTokens) / Double(max(1, totalTokens)) * 100))%")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)

                Divider().opacity(0.3)

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
            case .today, .week, .lastWeek: cap = 14
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
            } else {
                // 统一用柱状图渲染所有 range：日/周/上周/月/全部 都走同一套,
                // 视觉对齐 + 切 range 时视线连续。柱子 > 14 根时只显示 selected 柱
                // 的数字（避免 30+ 根柱子挤一起上方数字标签碰撞）。
                //
                // 生长动画：displayData 变化时（切 range / 刷新）柱高从旧值 spring
                // 到新值；每根柱 .id(d.date) + transition 让新柱从底部淡入弹起。
                let maxTokens = displayData.map(\.tokens).max() ?? 1
                let n = displayData.count
                let spacing: CGFloat = n > 20 ? 1.5 : (n > 10 ? 3 : 5)
                let showAllTexts: Bool = n <= 14
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(displayData.enumerated()), id: \.element.id) { idx, d in
                        trendBar(
                            d,
                            maxTokens: maxTokens,
                            isMax: d.tokens == maxTokens && maxTokens > 0,
                            showAllTexts: showAllTexts,
                            idx: idx,
                            total: n
                        )
                    }
                }
                .frame(height: 90)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: displayData)
            }
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: - 今日时段分布（热力条）
    //
    // 24 小时（0-23）垂直小条，高度按该小时 token 占比，颜色从弱到强
    // （brandFaint → brand 渐变热力感），直观看到一天哪时段最烧 token。
    // 仅在 range == .today 且 hourly 非空时显示。

    private var hourlyCard: some View {
        let buckets = viewModel.hourly  // [HourlyBucket] hour 0-23
        let maxTokens = buckets.map(\.tokens).max() ?? 1
        let peakHour = buckets.max { $0.tokens < $1.tokens }?.hour
        let nowHour = Calendar.current.component(.hour, from: Date())

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日时段分布")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let peak = peakHour {
                    Text("峰值 \(peak):00 · \(formatTokens(buckets.max(by: { $0.tokens < $1.tokens })?.tokens ?? 0))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.brand)
                }
            }

            // Canvas 显式绘制：24 格数学等分（同浮窗 HourlyHeatmapMini 修复），
            // 绕开 SwiftUI 嵌套布局的塌陷/错位。
            TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                Canvas { context, size in
                    let slot = size.width / 24
                    let barW: CGFloat = min(8, slot - 3)
                    let drawH: CGFloat = 36
                    let peak = peakHour
                    for hour in 0..<24 {
                        let tokens = buckets.first { $0.hour == hour }?.tokens ?? 0
                        let ratio = maxTokens > 0 ? Double(tokens) / Double(maxTokens) : 0
                        let h = max(3, CGFloat(ratio) * drawH)
                        let x = CGFloat(hour) * slot + (slot - barW) / 2
                        let y = size.height - h
                        let barColor = tokens == 0
                            ? Color.primary.opacity(0.05)
                            : (Theme.enablesThresholdColors
                                ? (ratio < 0.33 ? Theme.statusOK.opacity(0.45)
                                    : (ratio < 0.75 ? Theme.statusOK : Theme.statusWarn))
                                : Theme.brand.opacity(0.25 + 0.75 * ratio))
                        context.fill(
                            Path(roundedRect: CGRect(x: x, y: y, width: barW, height: h), cornerRadius: 1.5),
                            with: .color(barColor)
                        )
                        if tokens > 0, hour == peak {
                            let phase = ctx.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 2.0) / 2.0
                            let dot = CGRect(x: x + barW/2 - 1.5, y: y - 7, width: 3, height: 3)
                            context.fill(Path(ellipseIn: dot),
                                         with: .color(Theme.brand.opacity(0.4 + 0.6 * phase)))
                        }
                        if hour == nowHour {
                            let dot = CGRect(x: x + barW/2 - 1.5, y: size.height - 3, width: 3, height: 3)
                            context.fill(Path(ellipseIn: dot),
                                         with: .color(Theme.brand.opacity(0.6)))
                        }
                    }
                    context.fill(Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5)),
                                 with: .color(Color.primary.opacity(0.08)))
                }
            }
            .frame(height: 42)

            // 刻度：显式等分定位（与柱格同口径）
            GeometryReader { geo in
                let slot = geo.size.width / 24
                ForEach([0, 6, 12, 18, 23], id: \.self) { h in
                    Text("\(h)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .position(x: CGFloat(h) * slot + slot / 2, y: 5)
                }
            }
            .frame(height: 10)
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// 单根趋势柱（顶数字 + 柱体 + 底部日期标签）。
    /// 拆成独立函数避免 ForEach 闭包过重触发 Swift 类型检查超时。
    private func trendBar(
        _ d: DailyTotal,
        maxTokens: Int,
        isMax: Bool,
        showAllTexts: Bool,
        idx: Int,
        total: Int
    ) -> some View {
        VStack(spacing: 2) {
            if showAllTexts || isMax {
                Text(formatTokens(d.tokens))
                    .font(Theme.Typography.captionMonospaced)
                    .foregroundStyle(isMax ? Theme.brand : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text("0")
                    .font(Theme.Typography.captionMonospaced)
                    .foregroundStyle(.clear)
                    .lineLimit(1)
            }
            RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                .fill(isMax ? Theme.brandGradient : Theme.chartBar)
                .frame(height: barHeight(d.tokens, max: maxTokens))
            if showAllTexts || idx == 0 || idx == total - 1 || (total > 3 && idx == total / 2) {
                Text(String(d.date.suffix(5)))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(isMax ? Theme.brand.opacity(0.8) : Color.secondary.opacity(0.7))
            } else {
                Text("00/00")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.clear)
            }
        }
        .frame(maxWidth: .infinity)
        .id(d.date)
        .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: maxTokens)
    }

    private func barHeight(_ v: Int, max m: Int) -> CGFloat {
        guard m > 0 else { return 4 }
        // 防御除 0 / 负数 → NaN/Infinity（SwiftUI frame(height: nan) 会触发
        // CollectingViewsWithInvalidBaselines 异常导致切源时崩溃）
        let ratio = max(0, min(Double(v) / Double(m), 1.0))
        return max(4, CGFloat(ratio) * 60)
    }
}

// MARK: - Stagger Appear
//
// 卡片入场 stagger：切 tab 时每张卡按 index 错峰上浮淡入。
// 依赖 ContentView 的 tab state 变化（withAnimation 包裹），
// delay = index * 0.04s，形成逐个浮入的效果。

private extension View {
    /// 卡片入场 stagger：切 tab 时按 index 错峰上浮淡入
    func staggerAppear(tab: ContentView.Tab, index: Int) -> some View {
        modifier(StaggerAppear(tab: tab, index: index))
    }
}

private struct StaggerAppear: ViewModifier {
    let tab: ContentView.Tab
    let index: Int

    @State private var tabAppear = false

    init(tab: ContentView.Tab, index: Int) {
        self.tab = tab
        self.index = index
        // 每次 modifier 重建（tab 变化时 ContentView body 重建）都从隐藏态开始，
        // 再在 onAppear/onChange 里动画进入 → 形成"逐个浮入"
        _tabAppear = State(initialValue: false)
    }

    func body(content: Content) -> some View {
        content
            .opacity(tabAppear ? 1 : 0)
            .offset(y: tabAppear ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3).delay(Double(index) * 0.04)) {
                    tabAppear = true
                }
            }
            .onChange(of: tab) { _, _ in
                tabAppear = false
                withAnimation(.easeOut(duration: 0.3).delay(Double(index) * 0.04)) {
                    tabAppear = true
                }
            }
    }
}
