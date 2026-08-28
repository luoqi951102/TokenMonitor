import SwiftUI

// MARK: - BorderBeam（Linear 风格边框流光）
//
// 卡片边框上一段亮色"光束"沿边框匀速旋转，同色柔光拖尾。
// 实现：AngularGradient 窄亮段（透明→亮→透明）+ rotationEffect 随时间旋转，
// 叠一层 blur 同渐变做发光。TimelineView 20fps 驱动，开销极轻。

struct BorderBeam: ViewModifier {
    var color: Color
    var cornerRadius: CGFloat = 14
    var speed: Double = 6.0        // 秒/圈
    var beamFraction: Double = 0.22 // 光束占整圈比例
    var lineWidth: CGFloat = 1.4

    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let deg = t.truncatingRemainder(dividingBy: speed) / speed * 360.0
                beamShape(rotation: deg)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func beamShape(rotation: Double) -> some View {
        let gradient = AngularGradient(
            stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color.opacity(0), location: max(0, 1 - beamFraction - 0.06)),
                .init(color: color.opacity(0.9), location: max(0, 1 - 0.05)),
                .init(color: color.opacity(0), location: 1),
            ],
            center: .center
        )
        ZStack {
            // 发光层：模糊的同渐变描边
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(gradient, lineWidth: lineWidth * 2.2)
                .blur(radius: 2.5)
                .rotationEffect(.degrees(rotation))
            // 锐利层
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(gradient, lineWidth: lineWidth)
                .rotationEffect(.degrees(rotation))
        }
    }
}

extension View {
    /// 卡片边框流光（Linear/Arc 风格）
    func borderBeam(color: Color, cornerRadius: CGFloat = 14, speed: Double = 6.0) -> some View {
        modifier(BorderBeam(color: color, cornerRadius: cornerRadius, speed: speed))
    }
}

// MARK: - OrbitParticles（环轨道粒子能量流）
//
// 几颗小亮点沿圆轨道流动，各自带同色拖尾，透明度随角度呈"从暗到亮到暗"
// 的相位差——像能量脉冲绕环运行。放在 HeroRings 外环轨道上。

struct OrbitParticles: View {
    var radius: CGFloat = 48       // 轨道半径
    var color: Color = Theme.brand
    var count: Int = 4
    var speed: Double = 9.0        // 秒/圈
    var dotSize: CGFloat = 2.6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<count {
                    // 每颗粒子相位错开 1/count 圈
                    let phase = t / speed + Double(i) / Double(count)
                    let angle = phase * 2 * .pi
                    // 亮度跟相位走 sin：从暗到亮到暗（拖尾感）
                    let alpha = 0.25 + 0.75 * (0.5 + 0.5 * sin(angle * 2))
                    let alpha2 = 0.12 + 0.4 * (0.5 + 0.5 * sin(angle * 2 - 0.5))
                    let alpha3 = 0.05 + 0.2 * (0.5 + 0.5 * sin(angle * 2 - 1.0))
                    let p = CGPoint(x: center.x + cos(angle) * radius,
                                    y: center.y + sin(angle) * radius)
                    // 拖尾：沿轨道往回 2 颗渐弱的点
                    let p2 = CGPoint(x: center.x + cos(angle - 0.06) * radius,
                                     y: center.y + sin(angle - 0.06) * radius)
                    let p3 = CGPoint(x: center.x + cos(angle - 0.12) * radius,
                                     y: center.y + sin(angle - 0.12) * radius)
                    let head = Path(ellipseIn: CGRect(x: p.x - dotSize/2, y: p.y - dotSize/2,
                                                      width: dotSize, height: dotSize))
                    context.fill(head, with: .color(color.opacity(alpha)))
                    let mid = Path(ellipseIn: CGRect(x: p2.x - dotSize/2.4, y: p2.y - dotSize/2.4,
                                                     width: dotSize/1.2, height: dotSize/1.2))
                    context.fill(mid, with: .color(color.opacity(alpha2)))
                    let tail = Path(ellipseIn: CGRect(x: p3.x - dotSize/3, y: p3.y - dotSize/3,
                                                      width: dotSize/1.5, height: dotSize/1.5))
                    context.fill(tail, with: .color(color.opacity(alpha3)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 浮窗仪表盘组件集
//
// Hero 整体化设计（参考 Apple Fitness Activity Rings + 同色发光手法）：
//   1. HeroRings         — 三层同心发光环（外=CC / 中=ZC / 内=速率）+ 中心大数字，
//                          把多个指标融合成一个视觉锚点，解决"组件分散"问题
//   2. CompositionBar    — Token 构成四色分段条
//   3. HourlyHeatmapMini — 今日 24 小时热力条（峰值呼吸点）
//   4. VelocityGauge / SourceDonutCard — 旧版独立组件保留备用
//
// 全部沿用 Theme 设计系统（brand 渐变 / token 语义色 / modelColor），
// 数据从 DashboardViewModel 现有字段聚合，不需要新查询。

// MARK: - 1. Hero 多层同心发光环
//
// Apple Fitness 风格：三层同心环共用一个圆心，每环独立渐变色 + 圆头线帽 +
// 同色柔光（.shadow 用环自己的颜色），把 CC/ZC/速率三个指标融合成一个
// 视觉锚点。中心叠总 token 大数字 + 速率小字。
//
// 环语义（每环独立归一化，不是 100% 占比环）：
//   外环 brand   — CC token / max(CC, ZC)
//   中环 emerald — ZC token / max(CC, ZC)
//   内环 amber   — 当前速率 / 峰值速率

struct HeroRings: View {
    let claudeTokens: Int
    let zcodeTokens: Int
    let velocity: Double       // 当前速率
    let velocityPeak: Double   // 峰值速率
    var velocityUnit: String = "/时"

    private var ccFrac: Double {
        let m = Double(max(claudeTokens, zcodeTokens))
        return m > 0 ? Double(claudeTokens) / m : 0
    }
    private var zcFrac: Double {
        let m = Double(max(claudeTokens, zcodeTokens))
        return m > 0 ? Double(zcodeTokens) / m : 0
    }
    private var vFrac: Double {
        velocityPeak > 0 ? min(velocity / velocityPeak, 1) : 0
    }
    private var total: Int { claudeTokens + zcodeTokens }

    var body: some View {
        // 呼吸驱动：20fps TimelineView 算正弦相位，可见时常驻但计算极轻（几个 sin）
        //   breath    = sin(2π·t/4s)  → 光晕强弱 + 整体 1.2% scale 脉动
        //   flowDeg   = t/20s · 360°   → 渐变流光缓慢旋转（颜色绕环流动）
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = sin(2 * .pi * t / 4.0)
            let flowDeg = t.truncatingRemainder(dividingBy: 20.0) / 20.0 * 360.0
            ringsBody(breath: breath, flowDeg: flowDeg)
        }
    }

    private func ringsBody(breath: Double, flowDeg: Double) -> some View {
        HStack(spacing: 14) {
            // 环体（整组轻微呼吸缩放）
            ZStack {
                ringLayer(progress: ccFrac,
                          diameter: 96, lineWidth: 9,
                          color: Theme.brand, lightColor: Theme.brandLight,
                          breath: breath, flowDeg: flowDeg)
                ringLayer(progress: zcFrac,
                          diameter: 74, lineWidth: 9,
                          color: Theme.tokenCacheRead,
                          lightColor: Theme.tokenCacheRead.opacity(0.6),
                          breath: breath, flowDeg: flowDeg)
                ringLayer(progress: vFrac,
                          diameter: 54, lineWidth: 8,
                          color: Theme.tokenCacheWrite,
                          lightColor: Theme.tokenCacheWrite.opacity(0.6),
                          breath: breath, flowDeg: flowDeg)
                // 中心：总 token + 速率
                VStack(spacing: 0) {
                    Text(formatTokens(total))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: Double(total)))
                        .animation(.easeOut(duration: 0.3), value: total)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(rateText)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, height: 100)
            // 呼吸缩放：±1.2% 跟光晕同相位，非常轻微
            .scaleEffect(1.0 + 0.012 * breath)
            // 粒子能量流：4 颗亮点沿外环轨道绕行带拖尾（轨道半径 48 = 外环半径）
            .overlay(
                OrbitParticles(radius: 48, color: Theme.brand, count: 4, speed: 9.0)
                    .frame(width: 100, height: 100)
            )

            // 右侧图例：三行（色点 + 名 + 值）
            VStack(alignment: .leading, spacing: 7) {
                legendRow(color: Theme.brand, name: "CC",
                          value: formatTokens(claudeTokens), pct: pct(claudeTokens))
                legendRow(color: Theme.tokenCacheRead, name: "ZC",
                          value: formatTokens(zcodeTokens), pct: pct(zcodeTokens))
                legendRow(color: Theme.tokenCacheWrite, name: "速率",
                          value: rateText, pct: nil)
            }
        }
    }

    /// 单环：暗轨 + 渐变进度弧 + 同色柔光（光晕随 breath 脉动，渐变随 flowDeg 流光旋转）
    private func ringLayer(progress: Double, diameter: CGFloat, lineWidth: CGFloat,
                           color: Color, lightColor: Color,
                           breath: Double, flowDeg: Double) -> some View {
        // Aurora 皮肤辉光加强
        let boost: Double = SkinManager.shared.tokens.enablesGlow ? 1.6 : 1.0
        let breathAmt = 0.5 + 0.5 * breath
        let glowOpacity = (0.35 + 0.35 * breathAmt) * boost
        let glowRadius = (3.0 + 1.5 * breathAmt) * boost
        return ZStack {
            Circle()
                .stroke(color.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.003, progress))
                .stroke(
                    AngularGradient(
                        colors: [color, lightColor, color],
                        center: .center,
                        startAngle: .degrees(-90 + flowDeg),
                        endAngle: .degrees(270 + flowDeg)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                // 同色发光：亮度随呼吸相位脉动
                .shadow(color: color.opacity(glowOpacity), radius: glowRadius, x: 0, y: 0)
                .animation(.spring(response: 0.7, dampingFraction: 0.75), value: progress)
        }
        .frame(width: diameter, height: diameter)
    }

    private var rateText: String {
        let v = velocity
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) + velocityUnit }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) + velocityUnit }
        return String(format: "%.0f", v) + velocityUnit
    }

    private func pct(_ v: Int) -> String? {
        guard total > 0, v > 0 else { return nil }
        return "\(Int(Double(v) / Double(total) * 100))%"
    }

    private func legendRow(color: Color, name: String, value: String, pct: String?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 0) {
                Text(value)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()           // 禁止换行（"15.7M/时" 被拆两行的修复）
                    .minimumScaleFactor(0.85)
                if let pct {
                    Text(pct)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 96)
    }
}

// MARK: - 备用. 燃烧速率表盘（旧版独立组件，Hero 版已融合进 HeroRings）

struct VelocityGauge: View {
    let value: Double          // 当前速率
    let peak: Double           // 满量程（指针打到最右的值）
    let unit: String           // "/时" 或 "/天"
    var caption: String = "燃烧速率"

    private var ratio: Double {
        guard peak > 0 else { return 0 }
        return min(max(value / peak, 0), 1)
    }

    var body: some View {
        ZStack {
            // 背景暗轨：上半圆（trim 0.5→1.0 = 9点钟→3点钟经12点）
            Circle()
                .trim(from: 0.5, to: 1.0)
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            // 进度弧：按 ratio 截取
            Circle()
                .trim(from: 0.5, to: 0.5 + 0.5 * ratio)
                .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            // 刻度点：25% / 50% / 75% 三个小点（弧线上方轻标记）
            ForEach([0.25, 0.5, 0.75], id: \.self) { p in
                Circle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 2, height: 2)
                    .offset(gaugePoint(at: p, radius: 33))
            }
            // 指针：从中心指向弧线，按 ratio 旋转 -90°→+90°
            needle
                .rotationEffect(.degrees(-90 + 180 * ratio))
                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: ratio)
            // 中心帽
            Circle()
                .fill(Theme.brand)
                .frame(width: 5, height: 5)
            // 中心下方：数值 + 单位
            VStack(spacing: 0) {
                Spacer(minLength: 26)
                Text(formatRate(value))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: value))
                Text(unit)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 60)
        .overlay(alignment: .bottom) {
            Text(caption)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .offset(y: 14)
        }
    }

    /// 指针：细长三角从中心延伸，默认指向上方（12 点）
    private var needle: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: -2.2, y: -3))
            p.addLine(to: CGPoint(x: 0, y: -26))
            p.addLine(to: CGPoint(x: 2.2, y: -3))
            p.closeSubpath()
        }
        .fill(Theme.brand)
        .shadow(color: Theme.brand.opacity(0.4), radius: 1.5, y: 0)
    }

    /// 弧线上某比例处的坐标（供刻度点定位；角度 -90°→+90°）
    private func gaugePoint(at progress: Double, radius: CGFloat) -> CGSize {
        let angle = (-90 + 180 * progress) * .pi / 180
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }

    private func formatRate(_ v: Double) -> String {
        // 速率格式：<1M 用 K，≥1M 用 M 保留 1 位
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}

// MARK: - 备用. 来源占比环（旧版独立组件）

struct SourceDonutCard: View {
    let claudeTokens: Int
    let zcodeTokens: Int

    private var total: Int { claudeTokens + zcodeTokens }

    var body: some View {
        HStack(spacing: 10) {
            DonutChart(
                segments: [
                    DonutSegment(color: Theme.brand, value: Double(claudeTokens)),
                    DonutSegment(color: Theme.tokenCacheRead, value: Double(zcodeTokens)),
                ],
                ringWidth: 9,
                centerTitle: "总量",
                centerValue: formatTokens(total)
            )
            .frame(width: 74, height: 74)

            // 图例：两行（色点 + 名字 + 占比）
            VStack(alignment: .leading, spacing: 5) {
                legendRow(color: Theme.brand, name: "Claude", value: claudeTokens)
                legendRow(color: Theme.tokenCacheRead, name: "ZCode", value: zcodeTokens)
            }
        }
        .overlay(alignment: .bottom) {
            Text("来源占比")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .offset(y: 14)
        }
        .frame(height: 60, alignment: .top)
    }

    private func legendRow(color: Color, name: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 2)
            Text(pct(value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: 64)
    }

    private func pct(_ v: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int(Double(v) / Double(total) * 100))%"
    }
}

// MARK: - 2. Token 构成分段条
//
// 四色水平堆叠条：输入(indigo) / 缓存写(amber) / 缓存读(emerald) / 输出(pink)。
// 从 models 聚合四类 token，一眼看出成本结构大头。

struct CompositionBar: View {
    let models: [ModelUsage]

    private var inputT: Int { models.reduce(0) { $0 + $1.inputTokens } }
    private var cacheW: Int { models.reduce(0) { $0 + $1.cacheCreationTokens } }
    private var cacheR: Int { models.reduce(0) { $0 + $1.cacheReadTokens } }
    private var outputT: Int { models.reduce(0) { $0 + $1.outputTokens } }

    private var total: Int { inputT + cacheW + cacheR + outputT }

    /// 按 widthFraction 渲染的分段
    private struct Seg {
        let color: Color
        let name: String
        let value: Int
    }

    private func frac(_ seg: Seg) -> Double {
        total > 0 ? Double(seg.value) / Double(total) : 0
    }

    private var segs: [Seg] {
        [
            Seg(color: Theme.tokenInput, name: "输入", value: inputT),
            Seg(color: Theme.tokenCacheWrite, name: "缓存写", value: cacheW),
            Seg(color: Theme.tokenCacheRead, name: "缓存读", value: cacheR),
            Seg(color: Theme.tokenOutput, name: "输出", value: outputT),
        ]
        .filter { $0.value > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Token 构成")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("总 \(formatTokens(total))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // 四色分段条（GeometryReader 按占比切宽）
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(seg.color.opacity(0.9))
                            .frame(width: max(2, geo.size.width * frac(seg)))
                    }
                }
            }
            .frame(height: 8)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: total)

            // 图例：色点 + 名字 + 占比（隐藏 0 值项）
            HStack(spacing: 8) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 2) {
                        Circle().fill(seg.color).frame(width: 4, height: 4)
                        Text("\(seg.name) \(pct(seg.value))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func pct(_ v: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int(Double(v) / Double(total) * 100))%"
    }
}

// MARK: - 3. 今日时段热力条（mini 版）
//
// 主面板 hourlyCard 的浮窗缩小版：24 根热力条 + 峰值呼吸点 + 当前小时刻度。

struct HourlyHeatmapMini: View {
    let buckets: [HourlyBucket]

    /// 热力条颜色: Instrument 阈值三段(空闲灰/常规绿/高负载红->黄),
    /// 其他皮肤 brand 强度渐变
    private func heatmapColor(tokens: Int, ratio: Double) -> Color {
        if tokens == 0 { return Color.primary.opacity(0.05) }
        if Theme.enablesThresholdColors {
            // stats 式阈值: <33% 低活跃暗绿, <75% 常规绿, >=75% 高负载黄
            if ratio < 0.33 { return Theme.statusOK.opacity(0.45) }
            if ratio < 0.75 { return Theme.statusOK }
            return Theme.statusWarn
        }
        return Theme.brand.opacity(0.25 + 0.75 * ratio)
    }

    private var maxTokens: Int { buckets.map(\.tokens).max() ?? 1 }
    private var peakHour: Int? { buckets.max { $0.tokens < $1.tokens }?.hour }
    private var nowHour: Int { Calendar.current.component(.hour, from: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("今日时段")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let peak = peakHour, peak == nowHour {
                    Text("峰值进行中 \(peak):00")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.brand)
                } else if let peak = peakHour, let peakTokens = buckets.first(where: { $0.hour == peak })?.tokens {
                    Text("峰值 \(peak):00 · \(formatTokens(peakTokens))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            // Canvas 显式绘制：24 格数学等分，彻底绕开 SwiftUI 嵌套布局的
            // 塌陷/错位问题（此前柱子被画到数组索引位置且刻度漂移 2-3 小时）。
            // TimelineView 0.2s 重绘驱动峰值呼吸点。
            TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                Canvas { context, size in
                    let slot = size.width / 24
                    let barW: CGFloat = min(6, slot - 2)
                    let drawH: CGFloat = 26
                    let peak = peakHour
                    for hour in 0..<24 {
                        let tokens = buckets.first { $0.hour == hour }?.tokens ?? 0
                        let ratio = maxTokens > 0 ? Double(tokens) / Double(maxTokens) : 0
                        let h = max(2, CGFloat(ratio) * drawH)
                        let x = CGFloat(hour) * slot + (slot - barW) / 2
                        let y = size.height - h
                        let rect = CGRect(x: x, y: y, width: barW, height: h)
                        let path = Path(roundedRect: rect, cornerRadius: 1)
                        context.fill(path, with: .color(heatmapColor(tokens: tokens, ratio: ratio)))

                        // 峰值呼吸点（条顶上方）
                        if tokens > 0, hour == peak {
                            let phase = ctx.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 2.0) / 2.0
                            let dot = CGRect(x: x + barW/2 - 1.25, y: y - 6,
                                             width: 2.5, height: 2.5)
                            context.fill(Path(ellipseIn: dot),
                                         with: .color(Theme.brand.opacity(0.4 + 0.6 * phase)))
                        }
                        // 当前小时：底部小点
                        if hour == nowHour {
                            let dot = CGRect(x: x + barW/2 - 1.25, y: size.height - 2.5,
                                             width: 2.5, height: 2.5)
                            context.fill(Path(ellipseIn: dot),
                                         with: .color(Theme.brand.opacity(0.6)))
                        }
                    }
                    // 刻度基线（虚线感：低透明横线）
                    context.fill(Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5)),
                                 with: .color(Color.primary.opacity(0.08)))
                }
            }
            .frame(height: 30)

            // 刻度：显式等分定位（与柱格同宽口径），不再是 Spacer 均分（会漂移 2-3 小时）
            GeometryReader { geo in
                let slot = geo.size.width / 24
                ForEach([0, 6, 12, 18, 23], id: \.self) { h in
                    Text("\(h)")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .position(x: CGFloat(h) * slot + slot / 2, y: 5)
                }
            }
            .frame(height: 10)
        }
    }
}
