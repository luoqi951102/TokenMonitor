import WidgetKit
import SwiftUI

// MARK: - TokenWidget Widget Configuration

struct TokenWidget: Widget {
    let kind: String = "com.luoqi.tokenmonitor.widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            TokenWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetPanelBackground()
                }
        }
        .configurationDisplayName("Token Monitor")
        .description("查看本地 token 用量、模型对比与工具调用")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry View

struct TokenWidgetEntryView: View {
    var entry: WidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, entry.hasData {
                switch family {
                case .systemSmall:
                    SmallWidgetView(snapshot: snapshot)
                case .systemLarge:
                    LargeWidgetView(snapshot: snapshot)
                default:
                    MediumWidgetView(snapshot: snapshot)
                }
            } else {
                EmptyWidgetView()
            }
        }
    }
}

// MARK: - Background

private struct WidgetPanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.clear.background(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Theme.brand.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.06),
                    lineWidth: 0.8
                )
        }
    }
}

// MARK: - Empty State

private struct EmptyWidgetView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(Theme.brand)
            Text("等待数据")
                .font(.caption.weight(.semibold))
            Text("请先在 App 中运行 cc-usage sync")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
    }
}

// MARK: - Small Widget

private struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(Theme.brand)
                Text("Token")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Spacer()
            Text(formatTokens(snapshot.totalTokens))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.brand)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let top = snapshot.topModels.first {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.modelColor(top.model))
                        .frame(width: 6, height: 6)
                    Text(top.model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(rangeLabel(snapshot.range))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .widgetURL(URL(string: "tokenmonitor://refresh"))
    }
}

// MARK: - Medium Widget

private struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // 左：总览
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(Theme.brand)
                    Text("Token Monitor")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(formatTokens(snapshot.totalTokens))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.brand)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 10) {
                    metricPill(label: "消息", value: "\(snapshot.totalMsgs)", color: Theme.tokenCacheWrite)
                    metricPill(label: "工具", value: "\(snapshot.totalToolCalls)", color: Theme.tokenCacheRead)
                }
                Spacer(minLength: 0)
                Text("\(rangeLabel(snapshot.range)) · \(sourceLabel(snapshot.source))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            // 右：Top 3 模型
            VStack(alignment: .leading, spacing: 6) {
                Text("Top 模型")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(snapshot.topModels.prefix(3), id: \.model) { usage in
                    modelRow(usage)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .widgetURL(URL(string: "tokenmonitor://refresh"))
    }

    private func metricPill(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private func modelRow(_ usage: WidgetSnapshot.ModelUsage) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.modelColor(usage.model))
                .frame(width: 6, height: 6)
            Text(usage.model)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(formatTokens(usage.totalTokens))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Large Widget

private struct LargeWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(Theme.brand)
                    Text("Token Monitor")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Text("\(rangeLabel(snapshot.range)) · \(sourceLabel(snapshot.source))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTokens(snapshot.totalTokens))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.brand)
                    Text("总 Token")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(snapshot.totalMsgs)")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tokenCacheWrite)
                    Text("消息")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(snapshot.totalToolCalls)")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tokenCacheRead)
                    Text("工具调用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 趋势
            if !snapshot.daily.isEmpty {
                miniTrend
            }

            // Top 模型表
            VStack(alignment: .leading, spacing: 4) {
                Text("Top 模型")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(snapshot.topModels.prefix(4), id: \.model) { usage in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.modelColor(usage.model))
                            .frame(width: 6, height: 6)
                        Text(usage.model)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text(formatTokens(usage.totalTokens))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(usage.toolCallCount) 工具")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .widgetURL(URL(string: "tokenmonitor://refresh"))
    }

    private var miniTrend: some View {
        let maxTokens = snapshot.daily.map(\.tokens).max() ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            Text("趋势")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(snapshot.daily.suffix(14), id: \.date) { d in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.chartBar)
                            .frame(height: barHeight(d.tokens, max: maxTokens))
                    }
                }
            }
            .frame(height: 36)
        }
    }

    private func barHeight(_ v: Int, max m: Int) -> CGFloat {
        guard m > 0 else { return 2 }
        return max(2, CGFloat(v) / CGFloat(m) * 32)
    }
}

// MARK: - Helpers

private func rangeLabel(_ r: String) -> String {
    switch r {
    case "today": return "今日"
    case "week": return "本周"
    case "month": return "本月"
    case "all": return "全部"
    default: return r
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

private func formatTokens(_ tokens: Int) -> String {
    let v = Double(tokens)
    if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
    if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
    if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
    return "\(tokens)"
}

// MARK: - Theme (Widget 端独立副本，颜色保持一致)

private enum Theme {
    static let brand = Color(red: 0.357, green: 0.424, blue: 1.000)
    static let brandLight = Color(red: 0.475, green: 0.533, blue: 1.000)
    static let tokenCacheWrite = Color(red: 0.980, green: 0.702, blue: 0.282)
    static let tokenCacheRead = Color(red: 0.247, green: 0.741, blue: 0.580)

    static let chartBar = LinearGradient(
        colors: [brand.opacity(0.85), brandLight.opacity(0.45)],
        startPoint: .bottom, endPoint: .top
    )

    private static let palette: [Color] = [
        Color(red: 0.357, green: 0.424, blue: 1.000),
        Color(red: 0.980, green: 0.702, blue: 0.282),
        Color(red: 0.247, green: 0.741, blue: 0.580),
        Color(red: 0.886, green: 0.345, blue: 0.788),
        Color(red: 0.380, green: 0.804, blue: 0.890),
        Color(red: 0.847, green: 0.337, blue: 0.388),
        Color(red: 0.659, green: 0.510, blue: 0.890),
        Color(red: 0.345, green: 0.745, blue: 0.510),
    ]

    static func modelColor(_ name: String) -> Color {
        palette[abs(name.hashValue) % palette.count]
    }
}
