import SwiftUI

// MARK: - 浮窗仪表盘组件集
//
// 4 个酷炫仪表盘，供 FloatingWidgetView 的 large 档使用：
//   1. VelocityGauge    — 燃烧速率半圆表盘（指针 + 渐变弧）
//   2. SourceDonutCard  — CC vs ZC 来源占比环（复用 DonutChart）
//   3. CompositionBar   — Token 构成四色分段条
//   4. HourlyHeatmapMini— 今日 24 小时热力条（峰值呼吸点）
//
// 全部沿用 Theme 设计系统（brand 渐变 / token 语义色 / modelColor），
// 数据从 DashboardViewModel 现有字段聚合，不需要新查询。

// MARK: - 1. 燃烧速率表盘
//
// 半圆仪表：弧线从 9 点钟方向扫到 3 点钟方向，指针按 value/peak 比例偏转。
// 中心显示当前速率值 + 单位（今日档 = 每 小时，其他档 = 每 天）。
// 弧线用 brandGradient，指针 spring 旋转（数据变化时回弹）。

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

// MARK: - 2. 来源占比环（CC vs ZC）

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

// MARK: - 3. Token 构成分段条
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

// MARK: - 4. 今日时段热力条（mini 版）
//
// 主面板 hourlyCard 的浮窗缩小版：24 根热力条 + 峰值呼吸点 + 当前小时刻度。

struct HourlyHeatmapMini: View {
    let buckets: [HourlyBucket]

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

            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<24, id: \.self) { hour in
                    let tokens = buckets.first { $0.hour == hour }?.tokens ?? 0
                    let ratio = maxTokens > 0 ? Double(tokens) / Double(maxTokens) : 0
                    let isPeak = tokens > 0 && hour == peakHour
                    let isNow = hour == nowHour
                    VStack(spacing: 1) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(
                                    tokens == 0
                                        ? Color.primary.opacity(0.05)
                                        : Theme.brand.opacity(0.25 + 0.75 * ratio)
                                )
                                .frame(width: 4.5, height: max(2, CGFloat(ratio) * 26))
                                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: buckets)
                            if isPeak {
                                TimelineView(.periodic(from: Date(), by: 0.2)) { ctx in
                                    let phase = ctx.date.timeIntervalSince1970
                                        .truncatingRemainder(dividingBy: 2.0) / 2.0
                                    Circle()
                                        .fill(Theme.brand)
                                        .frame(width: 2.5, height: 2.5)
                                        .offset(y: -max(2, CGFloat(ratio) * 26) / 2 - 3)
                                        .opacity(0.4 + 0.6 * phase)
                                }
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        if isNow {
                            Circle()
                                .fill(Theme.brand.opacity(0.6))
                                .frame(width: 2.5, height: 2.5)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 34, alignment: .bottom)

            HStack(spacing: 1.5) {
                Text("0"); Spacer(); Text("6"); Spacer(); Text("12"); Spacer(); Text("18"); Spacer(); Text("23")
            }
            .font(.system(size: 7, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }
}
