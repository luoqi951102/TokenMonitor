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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.10),
                            lineWidth: 1
                        )
                }

            // 顶部品牌渐变光晕（淡淡的，不抢主体）
            LinearGradient(
                colors: [
                    Theme.brand.opacity(0.18),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            content
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.18), radius: 14, x: 0, y: 8)
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
        switch size {
        case .compact:  CompactContent(viewModel: viewModel)
        case .medium:   MediumContent(viewModel: viewModel)
        case .large:    LargeContent(viewModel: viewModel)
        }
    }
}

// MARK: - Range Switcher（小尺寸通用）

private struct RangeSwitcher: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UsageRange.allCases, id: \.self) { r in
                Button(action: { viewModel.range = r }) {
                    Text(r.displayName)
                        .font(.system(size: 10, weight: viewModel.range == r ? .bold : .medium))
                        .foregroundStyle(viewModel.range == r ? Color.white : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(viewModel.range == r ? Theme.brand : Color.clear)
                        )
                }
                .buttonStyle(.plain)
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
            }
            .padding(.horizontal, 10)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatTokens(viewModel.totalTokens))
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.brand)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("tokens")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)

            HStack(spacing: 12) {
                Label("\(viewModel.totalMsgs)", systemImage: "bubble.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Label("\(viewModel.totalToolCalls)", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }
}

// MARK: - Medium (280×196)

private struct MediumContent: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text("Token Monitor")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                RangeSwitcher(viewModel: viewModel)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTokens(viewModel.totalTokens))
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.brand)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("总 Token")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                kpi("\(viewModel.totalMsgs)", "消息", Theme.tokenCacheWrite)
                kpi("\(viewModel.totalToolCalls)", "工具", Theme.tokenCacheRead)
            }
            .padding(.horizontal, 14)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 5) {
                Text("Top 模型")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                ForEach(viewModel.topModels(3)) { usage in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.modelColor(usage.model))
                            .frame(width: 7, height: 7)
                        Text(usage.model)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(formatTokens(usage.totalTokens))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 12)
            Spacer(minLength: 0)
        }
    }

    private func kpi(_ v: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(v)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
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
                RangeSwitcher(viewModel: viewModel)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // KPI
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTokens(viewModel.totalTokens))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.brand)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("总 Token")
                        .font(.system(size: 10, weight: .medium))
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
                ForEach(viewModel.topModels(5)) { usage in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.modelColor(usage.model))
                            .frame(width: 7, height: 7)
                        Text(usage.model)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.quaternary.opacity(0.4))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.modelColor(usage.model).opacity(0.85))
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
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(data) { d in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.chartBar)
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(d.tokens, max: maxTokens))
                }
            }
            .frame(height: 30)
        }
    }

    private func barHeight(_ v: Int, max m: Int) -> CGFloat {
        guard m > 0 else { return 2 }
        return max(2, CGFloat(v) / CGFloat(m) * 26)
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
