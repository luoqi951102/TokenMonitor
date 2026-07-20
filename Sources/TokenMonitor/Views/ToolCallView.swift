import SwiftUI

// MARK: - Tool Call View
//
// 工具调用维度：
// - 工具调用排行（哪个模型最常调工具）
// - tool_calls / msg 比率（衡量"工具重"程度）
// - 工具调用日趋势（仅 zcode 来源有数据）

struct ToolCallView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCard
            rankingCard
            trendCard
        }
    }

    private var hasToolData: Bool {
        viewModel.models.contains { $0.toolCallCount > 0 }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(Theme.tokenCacheRead)
                Text("工具调用")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 16) {
                metric(label: "总调用数", value: formatNumber(viewModel.totalToolCalls))
                metric(label: "总消息数", value: formatNumber(viewModel.totalMsgs))
                let ratio = viewModel.totalMsgs > 0 ? Double(viewModel.totalToolCalls) / Double(viewModel.totalMsgs) : 0
                metric(label: "调用/消息", value: String(format: "%.2f", ratio))
            }
            if !hasToolData {
                Text("当前区间内没有工具调用数据（仅 ZCode 来源会记录 tool_call_count）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.tokenCacheRead)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Ranking

    private var rankingCard: some View {
        let ranked = viewModel.models
            .filter { $0.toolCallCount > 0 }
            .sorted { $0.toolCallCount > $1.toolCallCount }

        return VStack(alignment: .leading, spacing: 8) {
            Text("工具调用排行")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if ranked.isEmpty {
                Text("区间内无工具调用数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                let maxTools = ranked.first?.toolCallCount ?? 1
                ForEach(ranked.prefix(6)) { u in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.modelColor(u.model)).frame(width: 8, height: 8)
                        Text(u.model)
                            .font(.caption.weight(.medium))
                            .frame(width: 100, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.4))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.tokenCacheRead.opacity(0.85))
                                    .frame(width: geo.size.width * CGFloat(Double(u.toolCallCount) / Double(maxTools)))
                            }
                        }
                        .frame(height: 8)
                        Text("\(u.toolCallCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(String(format: "%.2f", u.toolCallsPerMsg))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(height: 18)
                }
                HStack {
                    Spacer()
                    Text("（右列 = 每消息工具调用数）")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Trend

    private var trendCard: some View {
        let withTools = viewModel.daily.filter { $0.toolCalls > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("工具调用趋势")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if withTools.isEmpty {
                Text("区间内无工具调用趋势数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                let maxTools = withTools.map(\.toolCalls).max() ?? 1
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(withTools.suffix(14)) { d in
                        VStack(spacing: 3) {
                            Text("\(d.toolCalls)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.tokenCacheRead.opacity(0.8))
                                .frame(width: 14, height: barHeight(d.toolCalls, max: maxTools))
                            Text(String(d.date.suffix(5)))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 70)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func barHeight(_ v: Int, max m: Int) -> CGFloat {
        guard m > 0 else { return 4 }
        return max(4, CGFloat(v) / CGFloat(m) * 50)
    }
}
