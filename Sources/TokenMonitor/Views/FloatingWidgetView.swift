import SwiftUI
import AppKit

// MARK: - FloatingWidgetView
//
// 桌面浮动小窗内容视图，三种尺寸。
// 数据全部来自 DashboardViewModel（已自动 sync + aggregate）。
//
// 设计原则（针对"看不清"问题）：
//   - 背景不透明度可调（默认 0.92，比 ultraThinMaterial 更稳）
//   - 字号比菜单栏面板大一档
//   - 关键数字用粗体+等宽，确保一眼可读
//   - 提供 range 切换（小窗自带，不依赖菜单栏面板）

struct FloatingWidgetView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let size: FloatingWidgetWindow.Size
    @Environment(\.colorScheme) private var colorScheme

    // 背景不透明度（用户可调，存 UserDefaults）
    @State private var opacity: Double = UserDefaults.standard.object(forKey: "floating_widget_opacity") as? Double ?? 0.92

    var body: some View {
        ZStack {
            // 实色背景（比 ultraThinMaterial 更可读）
            // 圆角对齐 Theme.Radius.panel，跟描边、阴影口径统一
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(backgroundMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                            lineWidth: 1
                        )
                }

            // 不再叠顶部品牌光晕（Slack/Notion 风，反 Apple HIG）；
            // 把"光感"交给整张面板的材质 + 边界 hairline 自然承担。

            content
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.16), radius: 14, x: 0, y: 8)
        .onReceive(NotificationCenter.default.publisher(for: .floatingWidgetOpacityChanged)) { note in
            if let v = note.object as? Double {
                opacity = v
            }
        }
    }

    private var backgroundMaterial: Color {
        let base = colorScheme == .dark
            ? Color(red: 0.10, green: 0.11, blue: 0.14)
            : Color(red: 0.96, green: 0.97, blue: 1.0)
        return base.opacity(opacity)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch size {
            case .compact:  CompactContent(viewModel: viewModel)
            case .medium:   MediumContent(viewModel: viewModel)
            case .large:    LargeContent(viewModel: viewModel)
            }
        }
        .id(size)  // 让 size 切换时整个内容重新创建（配合 transition）
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

// MARK: - Range Switcher（小尺寸通用）

private struct RangeSwitcher: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageRange.allCases, id: \.self) { r in
                let isSelected = viewModel.range == r
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        viewModel.range = r
                    }
                }) {
                    Text(r.displayName)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Theme.brand)
                                        .matchedGeometryEffect(id: "rangeBg", in: ns)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.black.opacity(colorSchemeLocal == .dark ? 0.3 : 0.06))
        )
    }

    @Environment(\.colorScheme) private var colorSchemeLocal
}

// MARK: - Source Switcher（全部 / Claude / ZCode）

private struct SourceSwitcher: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Namespace private var ns

    private let options: [(value: String, label: String)] = [
        ("all", "全部"), ("claude", "Claude"), ("zcode", "ZCode")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let isSelected = viewModel.source == opt.value
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        viewModel.source = opt.value
                    }
                }) {
                    Text(opt.label)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Theme.brandDark)
                                        .matchedGeometryEffect(id: "sourceBg", in: ns)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.black.opacity(colorSchemeLocal == .dark ? 0.3 : 0.06))
        )
    }

    @Environment(\.colorScheme) private var colorSchemeLocal
}

/// 浮动小窗的筛选条：range + source 两个 Switcher 横排，中间细分隔
struct FloatingFilterBar: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 6) {
            RangeSwitcher(viewModel: viewModel)
            Divider().frame(height: 16).opacity(0.3)
            SourceSwitcher(viewModel: viewModel)
        }
    }
}

// MARK: - 手动刷新按钮（悬浮窗右上角）
//
// 点击触发 viewModel.manualSync()：
//  - sandbox 下真实 sync 由 launchd / 终端执行，这里只重新读 DB + refresh + pushWidgetSnapshot
//  - 旋转用经典 rotationEffect + repeatForever（兼容 macOS 14+，
//    SF Symbol .rotate/.repeat 在 macOS 15+ 才有，不强依赖）
//  - hit 区遵循 Apple HIG 最低 24×24，避免在小菜单里手滑点空
//  - hover 态：背景 0.06 系统灰圈，跟 macOS Tahoe 按钮 hover 行为对齐
// 三种尺寸共用，size 控制视觉图标大小，hitSize 固定 ≥ 24。

private struct RefreshIconButton: View {
    @ObservedObject var viewModel: DashboardViewModel
    var size: CGFloat = 12
    var hitSize: CGFloat = 24  // Apple HIG 最低触达尺寸

    @State private var rotating: Bool = false
    @State private var hovering: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            // 立即开启旋转动画，避免 syncNow 内部 300ms sleep 让用户感觉无响应
            rotating = true
            Task { @MainActor in
                await viewModel.manualSync()
                rotating = false
            }
        } label: {
            ZStack {
                // hover 圈含（macOS Tahoe 按钮 hover 行为：极淡灰圈）
                if hovering {
                    Circle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                        .frame(width: hitSize, height: hitSize)
                }
                // 图标本体：semibold → medium，更克制
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .animation(
                        rotating
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.2),
                        value: rotating
                    )
                    .frame(width: size, height: size)
            }
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .help(rotating ? "同步中..." : "重新读取数据库并刷新")
        .accessibilityLabel("刷新")
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Compact (180×96) — 比之前稍高，给 range 留位置

private struct CompactContent: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text("Token")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                RangeSwitcher(viewModel: viewModel)
                    .scaleEffect(0.85)
                RefreshIconButton(viewModel: viewModel, size: 10)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 10)

            // 注：曾用 alignment: .firstTextBaseline + 同 HStack 内 Spacer，
            // 但 .contentTransition(.numericText) 过渡过程中 Spacer 无 baseline，
            // 触发 SwiftUI 内部 CollectingViewsWithInvalidBaselines 异常 → 切源时闪退。
            // 改 .center 既安全又几乎不动视觉。
            HStack(alignment: .center, spacing: 4) {
                Text(formatTokens(viewModel.totalTokens))
                    .font(Theme.Typography.metric)
                    .baselineOffset(2)  // 视觉补偿，让大数字与小字 "tokens" 仍然近似底对齐
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(viewModel.totalTokens)))
                    .animation(.easeOut(duration: 0.3), value: viewModel.totalTokens)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("tokens")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)

            HStack(spacing: 12) {
                Label("\(viewModel.totalMsgs)", systemImage: "bubble.right")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(viewModel.totalMsgs)))
                    .animation(.easeOut(duration: 0.3), value: viewModel.totalMsgs)
                Label("\(viewModel.totalToolCalls)", systemImage: "wrench.and.screwdriver")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(viewModel.totalToolCalls)))
                    .animation(.easeOut(duration: 0.3), value: viewModel.totalToolCalls)
                Spacer()
            }
            .padding(.horizontal, 10)

            // 7-day mini sparkline：1px hairline，跟读完 KPI 行后能立即看到近 7 天走势
            // 只有 range=today 时显示，避免在 other range 上给重复信息
            if viewModel.range == .today, !viewModel.daily.isEmpty {
                MiniSparkline(daily: Array(viewModel.daily.suffix(7)))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            } else {
                Spacer(minLength: 0).padding(.bottom, 8)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Mini Sparkline（极小 1px hairline，给 Compact 用）

private struct MiniSparkline: View {
    let daily: [DailyTotal]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxTokens = max(daily.map(\.tokens).max() ?? 1, 1)
            let stepX = daily.count > 1 ? w / CGFloat(daily.count - 1) : w
            let points = daily.enumerated().map { (i, d) -> CGPoint in
                let x = CGFloat(i) * stepX
                let y = h - (CGFloat(d.tokens) / CGFloat(maxTokens)) * (h - 2) - 1
                return CGPoint(x: x, y: y)
            }

            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() {
                        p.addLine(to: pt)
                    }
                }
                .stroke(
                    Theme.brand.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                )

                // 末端 accent dot（最新一天）
                if let last = points.last {
                    Circle()
                        .fill(Theme.brand)
                        .frame(width: 3, height: 3)
                        .position(last)
                }
            }
        }
        .frame(height: 18)
    }
}

// MARK: - Medium (320×260) - 扩容版，含 streak + 模型 + 项目

private struct MediumContent: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text("Token Monitor")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                RefreshIconButton(viewModel: viewModel, size: 11)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // 筛选条：range + source
            FloatingFilterBar(viewModel: viewModel)
                .padding(.horizontal, 14)

            // KPI 行 + streak 简版（火苗）
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTokens(viewModel.totalTokens))
                        .font(Theme.Typography.metric)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: Double(viewModel.totalTokens)))
                        .animation(.easeOut(duration: 0.3), value: viewModel.totalTokens)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("总 Token")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                kpi("\(viewModel.totalMsgs)", "消息", Theme.tokenCacheWrite)
                kpi("\(viewModel.totalToolCalls)", "工具", Theme.tokenCacheRead)
                // streak 简版
                VStack(spacing: 0) {
                    Image(systemName: viewModel.streak.current > 0 ? "flame.fill" : "flame")
                        .font(.system(size: 13))
                        .foregroundStyle(viewModel.streak.current > 0 ? Color.orange : Color.gray.opacity(0.5))
                    Text("\(viewModel.streak.current)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(viewModel.streak.current > 0 ? Color.orange : Color.secondary)
                    Text("天")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 38)
            }
            .padding(.horizontal, 14)

            Divider().opacity(0.4)

            // 双栏：Top 模型 + Top 项目
            HStack(alignment: .top, spacing: 12) {
                // 左：Top 模型
                VStack(alignment: .leading, spacing: 3) {
                    Text("Top 模型")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(viewModel.topModels(3)) { usage in
                        let providerName = providerDisplayName(usage.provider, model: usage.model)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Theme.modelColor(usage.model + usage.provider))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(usage.model)
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                // 次行：provider 后追加来源短标签 CC/ZC（窄空间用短名）
                                let srcShort = UsageSource(rawValue: usage.source)?.shortLabel ?? usage.source
                                Text(providerName.isEmpty ? srcShort : "\(providerName) · \(srcShort)")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 2)
                            Text(formatTokens(usage.totalTokens))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 右：Top 项目
                VStack(alignment: .leading, spacing: 3) {
                    Text("Top 项目")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    let projects = viewModel.topProjects(3)
                    ForEach(projects) { p in
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(Theme.tokenCacheWrite.opacity(0.8))
                            Text(lastPathComponent(p.project))
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 2)
                            Text(formatTokens(p.tokens))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if projects.isEmpty {
                        Text("无")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Spacer(minLength: 0)
        }
    }

    private func kpi(_ v: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(v)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Large (340×340)

private struct LargeContent: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text("Token Monitor")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                RefreshIconButton(viewModel: viewModel, size: 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // 筛选条：range + source
            FloatingFilterBar(viewModel: viewModel)
                .padding(.horizontal, 16)

            // KPI + streak 简版
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTokens(viewModel.totalTokens))
                        .font(Theme.Typography.metric)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: Double(viewModel.totalTokens)))
                        .animation(.easeOut(duration: 0.3), value: viewModel.totalTokens)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("总 Token")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(viewModel.totalMsgs)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tokenCacheWrite)
                    Text("消息")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(viewModel.totalToolCalls)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tokenCacheRead)
                    Text("工具")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                // streak 火苗
                VStack(spacing: 0) {
                    Image(systemName: viewModel.streak.current > 0 ? "flame.fill" : "flame")
                        .font(.system(size: 14))
                        .foregroundStyle(viewModel.streak.current > 0 ? Color.orange : Color.gray.opacity(0.5))
                    Text("\(viewModel.streak.current)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(viewModel.streak.current > 0 ? Color.orange : Color.secondary)
                    Text("/ \(viewModel.streak.longest) 天")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 44)
            }
            .padding(.horizontal, 16)

            Divider().opacity(0.4)

            // Mini Trend
            if !viewModel.daily.isEmpty {
                miniTrend
                    .padding(.horizontal, 16)
            }

            // Top Models
            VStack(alignment: .leading, spacing: 6) {
                Text("Top 模型")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                let maxTotal = viewModel.models.first?.totalTokens ?? 1
                ForEach(viewModel.topModels(8)) { usage in
                    let providerName = providerDisplayName(usage.provider, model: usage.model)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.modelColor(usage.model + usage.provider))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(usage.model)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // 次行：provider 后追加来源短标签 CC/ZC（浮窗空间窄用短名）
                            let srcShort = UsageSource(rawValue: usage.source)?.shortLabel ?? usage.source
                            Text(providerName.isEmpty ? srcShort : "\(providerName) · \(srcShort)")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.quaternary.opacity(0.4))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.modelColor(usage.model + usage.provider).opacity(0.85))
                                    .frame(width: max(2, geo.size.width * CGFloat(Double(usage.totalTokens) / Double(maxTotal))))
                            }
                        }
                        .frame(height: 7)
                        Text(formatTokens(usage.totalTokens))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .frame(height: 16)
                    .padding(.horizontal, 16)
                }
            }

            // Top 项目
            VStack(alignment: .leading, spacing: 4) {
                Text("Top 项目")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                let projects = viewModel.topProjects(3)
                let maxProjTokens = projects.first?.tokens ?? 1
                ForEach(projects) { p in
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.tokenCacheWrite.opacity(0.8))
                        Text(lastPathComponent(p.project))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 130, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.quaternary.opacity(0.4))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(
                                        LinearGradient(
                                            colors: [Theme.tokenCacheWrite, Theme.tokenCacheRead],
                                            startPoint: .leading, endPoint: .trailing
                                        ).opacity(0.85)
                                    )
                                    .frame(width: max(2, geo.size.width * CGFloat(Double(p.tokens) / Double(maxProjTokens))))
                            }
                        }
                        .frame(height: 6)
                        Text(formatTokens(p.tokens))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(width: 46, alignment: .trailing)
                    }
                    .frame(height: 14)
                    .padding(.horizontal, 16)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var miniTrend: some View {
        let data = Array(viewModel.daily.suffix(14))
        let maxTokens = data.map(\.tokens).max() ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("趋势")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.rangeLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            // 注：曾用 HStack(alignment: .bottom) 让柱子底部对齐，但 .bottom 对齐
            // 在纯图形子项（RoundedRectangle，无 baseline anchor）上 macOS 14 会
            // 触发 CollectingViewsWithInvalidBaselines ObjC 异常 → SwiftUI 切源重建时崩。
            // 改 HStack 默认 .center 对齐 + 每根柱用 frame(maxHeight:.infinity, alignment:.bottom)
            // 既达到底部对齐效果又不依赖 baseline。
            HStack(spacing: 2) {
                ForEach(data) { d in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.chartBar)
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(d.tokens, max: maxTokens), alignment: .bottom)
                }
            }
            .frame(height: 30, alignment: .bottom)
        }
    }

    private func barHeight(_ v: Int, max m: Int) -> CGFloat {
        guard m > 0 else { return 2 }
        // 防御除 0 / 负数 → NaN（anya_frame(height: nan) 触发 baseline 异常崩溃）
        let ratio = max(0, min(Double(v) / Double(m), 1.0))
        return max(2, CGFloat(ratio) * 26)
    }
}

// MARK: - Helpers

private func rangeLabel(_ r: UsageRange) -> String {
    r.displayName
}

private func sourceLabel(_ s: String) -> String {
    switch s {
    case "all": return "全部"
    case "claude": return "Claude"
    case "zcode": return "ZCode"
    default: return s
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let floatingWidgetOpacityChanged = Notification.Name("floatingWidgetOpacityChanged")
    /// 浮动小窗请求打开主面板（MenuBarManager 监听）
    static let floatingWidgetRequestOpenMain = Notification.Name("floatingWidgetRequestOpenMain")
}
