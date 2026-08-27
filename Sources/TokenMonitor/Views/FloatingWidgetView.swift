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
    @State private var pressing: Bool = false      // 按下时缩放反馈
    @State private var successFlash: Bool = false  // sync 成功后图标短暂高亮
    @State private var countdownDigit: Int? = nil  // 最后 3 秒倒计时数字 3/2/1，nil 表示未进入
    @State private var digitTick: Int = 0          // 数字切换 tick（驱动 spring scale 动画）
    @State private var urgent: Bool = false        // 最后 3 秒整体紧迫态（环加粗+脉动）
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            // 立即开启旋转动画，避免 syncNow 内部 300ms sleep 让用户感觉无响应
            rotating = true
            countdownDigit = nil  // 手动触发时取消 3-2-1 数字，回到旋转图标
            urgent = false
            Task { @MainActor in
                await viewModel.manualSync()
                rotating = false
                // 成功完成 → 触发 0.7s 高亮闪一下，让用户明确感知"我刚刷过了"
                successFlash = true
                try? await Task.sleep(nanoseconds: 700_000_000)
                successFlash = false
            }
        } label: {
            ZStack {
                // hover 圈含（macOS Tahoe 按钮 hover 行为：极淡灰圈）
                if hovering {
                    Circle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                        .frame(width: hitSize, height: hitSize)
                }
                // 1 分钟自动刷新倒计时环：基于上次真实 syncAt 推剩余秒数
                // （不是 epoch 取余；这样环归零的瞬间正好对齐下一次 timer 触发）。
                // last 3 秒会触发 urgent 态让 CountdownRing 自己加粗并脉动，
                // 同时 icon 位置切换成 3-2-1 数字 spring 跳动。
                if let interval = viewModel.syncRunner.intervalMinutes as Int?, interval > 0 {
                    RefreshCountdownRing(
                        intervalSeconds: TimeInterval(interval * 60),
                        lastSyncAt: viewModel.syncRunner.lastSyncAt ?? Date(),
                        ringSize: hitSize,
                        ringColor: successFlash
                            ? Theme.brand
                            : (urgent ? Theme.brand : Theme.brand.opacity(0.5)),
                        lineWidth: urgent ? 1.8 : 1.2,
                        urgent: urgent,
                        onLast3Seconds: { secs in
                            // 进入最后 3 秒；secs = 3/2/1（向下取整的剩余秒）
                            // 每秒只触发一次（secs 变了才更新），驱动数字 spring 动画
                            if countdownDigit != secs {
                                countdownDigit = secs
                                digitTick &+= 1
                                urgent = true
                            }
                        },
                        onReset: {
                            // lastSyncAt 跳过了 60s（下一轮 sync 已触发），退出 urgent
                            if countdownDigit != nil || urgent {
                                countdownDigit = nil
                                urgent = false
                            }
                        }
                    )
                }
                // 图标 / 倒计时数字 位置互相切换：
                //   常规态 → arrow.clockwise icon
                //   最后 3 秒 → 3/2/1 大数字 spring scale 跳入
                //   sync 中 / 手动按下 → 仍是 icon 旋转
                if let d = countdownDigit, !rotating {
                    CountdownDigitView(
                        digit: d,
                        tick: digitTick,
                        color: Theme.brand
                    )
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(successFlash ? Theme.brand : Color.secondary)
                        .rotationEffect(.degrees(rotating ? 360 : 0))
                        .animation(
                            rotating
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .easeOut(duration: 0.2),
                            value: rotating
                        )
                        .frame(width: size, height: size)
                }
            }
            .scaleEffect(pressing ? 0.85 : 1.0)
            // urgency pulse：最后 3 秒整按钮 1.0 → 1.08 spring 跳一下，每秒一次
            .scaleEffect(urgent ? 1.0 + 0.04 * sin(Double(digitTick) * .pi / 2) : 1.0)
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded { _ in pressing = false }
        )
        .help(rotating ? "同步中..." : "重新读取数据库并刷新")
        .accessibilityLabel("刷新")
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: pressing)
        .animation(.easeOut(duration: successFlash ? 0.25 : 0.4), value: successFlash)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: urgent)
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: countdownDigit)
    }
}

// MARK: - 最后 3 秒倒计时数字视图
//
// 每秒进入一个新的 digit（3→2→1），spring scale 从 1.4 → 1.0 + opacity 1 → 0.3
// 衰减，配合 radial glow 给"火箭发射倒计时"既视感。
private struct CountdownDigitView: View {
    let digit: Int
    let tick: Int  // 每秒切换时 +1，用于驱动 spring 动画
    let color: Color

    var body: some View {
        // tick 作为 id 让 SwiftUI 在数字切换时重建 view 触发 .transition spring
        let _ = tick
        ZStack {
            // 发光辐射：径向渐变从中心 brand 色淡出到透明，给"数字身后光晕"既视感
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(
                            colors: [color.opacity(0.45), color.opacity(0.0)]
                        ),
                        center: .center,
                        startRadius: 0,
                        endRadius: 10
                    )
                )
                .frame(width: 16, height: 16)
                .blur(radius: 1.5)
            // 数字本身：bold + brand 色，spring scale 跳进来
            Text("\(digit)")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .transition(.scale(scale: 1.5).combined(with: .opacity))
        }
    }
}

// MARK: - 每分钟自动刷新倒计时环
//
// 基于"上次 sync 完成时刻"推剩余时间，跟 SyncRunner 真实 timer 对齐。
// phase = (now - lastSyncAt) / intervalSeconds，截断 [0, 1]：
//   - sync 刚完成的瞬间 → phase ≈ 0，环几乎空白
//   - 距下次 sync 临近  → phase ≈ 1，环几乎走满
//   - timer 触发并完成下一个 sync → lastSyncAt 更新，环自然归零
// 这跟之前用 epoch 取余完全不同：epoch 取余跟 timer 触发时机无关，
// 环走完一圈不一定真触发 sync，sync 也不一定发生在环归零的瞬间。
//
// 最后 3 秒通过 onLast3Seconds 回调告诉父视图进入"紧迫态"：
//   - 剩余秒数 = ceil(interval - elapsed)（3 → 2 → 1 每秒一次）
//   - 父视图据此切换 icon → 3/2/1 大数字 + 整按钮 pulse
//   - 当 lastSyncAt 跨过 60s（下一轮启动），onReset 让父视图退出紧迫态
private struct RefreshCountdownRing: View {
    let intervalSeconds: TimeInterval
    let lastSyncAt: Date
    let ringSize: CGFloat
    let ringColor: Color
    var lineWidth: CGFloat = 1.2
    var urgent: Bool = false
    var onLast3Seconds: ((Int) -> Void)? = nil
    var onReset: (() -> Void)? = nil

    // 记上一次上报的剩余秒数，避免每秒多次回调
    @State private var lastReportedSecs: Int = -1

    var body: some View {
        // .periodic 每 0.25s 触发一次重建（最后 3 秒需要更细的精度捕捉 3→2→1 切换）
        TimelineView(.periodic(from: Date(), by: 0.25)) { context in
            let elapsed = context.date.timeIntervalSince(lastSyncAt)
            let remaining = max(0, intervalSeconds - elapsed)
            let phase = intervalSeconds > 0
                ? max(0, min(elapsed / intervalSeconds, 1.0))
                : 0

            // 进入"最后 3 秒"通知：remaining ∈ (0, 3] 时，secs = ceil(remaining) ∈ {1,2,3}
            // only 触发 secs 改变的时刻，避免每 0.25s 帧都回调。
            //
            // 注意：SwiftUI ViewBuilder 闭包要求返回 View，side effect 必须
            // 用 onChange 包成 view。这里用 EmptyView().onChange(of:) 把回调挂上去，
            // 不破坏 TimelineView 的 Content 类型推断。
            let secsNow = (remaining > 0 && remaining <= 3.0)
                ? Int(remaining.rounded(.up))  // 2.7→3, 1.9→2, 0.5→1
                : -1
            let _ = Self.reportTick(secsNow, last: lastReportedSecs) { newSecs in
                if newSecs > 0 {
                    onLast3Seconds?(newSecs)
                } else {
                    onReset?()
                }
                lastReportedSecs = newSecs
            }

            ZStack {
                // 背景暗轨
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1.2)
                    .frame(width: ringSize - 2, height: ringSize - 2)
                // 进度弧（从 12 点钟方向顺时针走）
                // urgent 态描线加粗，颜色饱和度由 ringColor 决定（父视图 urgent 时传 Theme.brand）
                Circle()
                    .trim(from: 0, to: max(0.001, phase))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: ringSize - 2, height: ringSize - 2)
                    // urgency 时进度弧叠加柔光
                    .shadow(color: urgent ? ringColor.opacity(0.6) : .clear, radius: urgent ? 3 : 0)
            }
        }
    }

    /// 把"剩余秒数变化时触发回调"的 side effect 包成静态函数，避免在 ViewBuilder
    /// 闭包里直接调用破坏类型推断。只在 secsNow != last 时调用一次 callback。
    @inline(__always)
    private static func reportTick(_ secsNow: Int, last: Int, callback: @escaping (Int) -> Void) {
        guard secsNow != last else { return }
        DispatchQueue.main.async { callback(secsNow) }
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
                    // 每次刷新后大数字短暂放大一下（sync 成功 → 数字"跳出来"）
                    .scaleEffect(viewModel.refreshPulse ? 1.06 : 1.0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: viewModel.refreshPulse)
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
                        // 刷新后大数字短暂放大 spring 一下，给"数据刷新了"留视觉印记
                        .scaleEffect(viewModel.refreshPulse ? 1.06 : 1.0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: viewModel.refreshPulse)
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
                    .foregroundStyle(Theme.brandGradient)
                    .shadow(color: Theme.brand.opacity(0.6), radius: 3, x: 0, y: 0)
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
                        // 刷新后大数字短暂放大 spring 一下
                        .scaleEffect(viewModel.refreshPulse ? 1.06 : 1.0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: viewModel.refreshPulse)
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

            // ===== 仪表盘区（统一卡片容器，整体感）=====
            VStack(alignment: .leading, spacing: 12) {
                // Hero 三层同心发光环（CC / ZC / 速率 融合在一个视觉锚点）
                HeroRings(
                    claudeTokens: viewModel.models.filter { $0.source == "claude" }.reduce(0) { $0 + $1.totalTokens },
                    zcodeTokens: viewModel.models.filter { $0.source == "zcode" }.reduce(0) { $0 + $1.totalTokens },
                    velocity: velocityValue,
                    velocityPeak: velocityPeak,
                    velocityUnit: viewModel.range == .today ? "/时" : "/天"
                )
                .frame(maxWidth: .infinity)

                // Token 构成四色分段条
                if !viewModel.models.isEmpty {
                    CompositionBar(models: viewModel.models)
                }

                // 今日时段热力条（仅今日档显示）
                if viewModel.range == .today && !viewModel.hourly.isEmpty {
                    HourlyHeatmapMini(buckets: viewModel.hourly)
                }
            }
            .padding(12)
            .background(
                // 统一卡片底：把 Hero + 构成 + 热力 三块视觉上框成一块
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // 轻微浮动：整卡 ±1.5pt 8s 正弦上下漂（跟 Hero 呼吸不同频，叠加更自然）
            .modifier(GentleFloat(amplitude: 1.5, period: 8.0))
            .padding(.horizontal, 16)
            .padding(.vertical, 2)

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
                ForEach(viewModel.topModels(5)) { usage in
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

    // MARK: - 燃烧速率计算
    //
    // 今日档：value = 今日 token ÷ 已过小时数（当前小时 + 分钟比例，至少 1 避免除 0），
    //         peak = 今日峰值小时的 token（指针打到最右 = 追平历史峰值速度）。
    // 其他档：value = 区间 token ÷ 区间天数（日均），peak = 区间内单日最大。

    private var hoursElapsedToday: Double {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return max(1, Double(comps.hour ?? 1) + Double(comps.minute ?? 0) / 60.0)
    }

    private var velocityValue: Double {
        if viewModel.range == .today {
            return Double(viewModel.totalTokens) / hoursElapsedToday
        }
        let days = max(1, viewModel.daily.count)
        return Double(viewModel.totalTokens) / Double(days)
    }

    private var velocityPeak: Double {
        if viewModel.range == .today {
            let peakHourly = viewModel.hourly.map(\.tokens).max() ?? 0
            // 峰值小时 token 就是"满速"，保证指针通常在中间偏左（当前均值 < 峰值）
            return Double(max(peakHourly, 1))
        }
        let peakDaily = viewModel.daily.map(\.tokens).max() ?? 1
        return Double(max(peakDaily, 1))
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
                    let isMax = d.tokens == maxTokens && maxTokens > 0
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isMax ? Theme.brandGradient : Theme.chartBar)
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(d.tokens, max: maxTokens), alignment: .bottom)
                        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: data)
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

// MARK: - Gentle Float（轻微上下浮动）
//
// 仪表盘卡片的 idle 漂浮感：TimelineView 20fps 驱动正弦 y 偏移，
// 幅度默认 ±1.5pt / 8s 周期，与 Hero 环的 4s 呼吸不同频叠加更自然。

struct GentleFloat: ViewModifier {
    var amplitude: CGFloat = 1.5
    var period: Double = 8.0

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let y = amplitude * CGFloat(sin(2 * .pi * t / period))
            content.offset(y: y)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let floatingWidgetOpacityChanged = Notification.Name("floatingWidgetOpacityChanged")
    /// 浮动小窗请求打开主面板（MenuBarManager 监听）
    static let floatingWidgetRequestOpenMain = Notification.Name("floatingWidgetRequestOpenMain")
}
