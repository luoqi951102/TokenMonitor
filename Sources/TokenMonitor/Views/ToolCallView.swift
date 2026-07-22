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
                // 表头
                HStack(spacing: 8) {
                    Text("模型")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 110, alignment: .leading)
                    Text("工具调用")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                    Text("次数")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                    Text("次/消息")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                }
                Divider()
                ForEach(ranked.prefix(8)) { u in
                    let providerName = providerDisplayName(u.provider, model: u.model)
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.modelColor(u.model + u.provider)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(u.model)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !providerName.isEmpty {
                                    Text(providerName)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.4))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.tokenCacheRead.opacity(0.85))
                                    .frame(width: max(4, geo.size.width * CGFloat(Double(u.toolCallCount) / Double(maxTools))))
                            }
                        }
                        .frame(height: 10)
                        Text("\(u.toolCallCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(String(format: "%.2f", u.toolCallsPerMsg))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
                if ranked.count > 8 {
                    Text("+ 其余 \(ranked.count - 8) 个模型未展示")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
        // 区间密度自适应：range=all 时按周聚合避免柱过密
        let display: [DailyTotal] = {
            switch viewModel.range {
            case .all:
                // 按周聚合（每周 = 该周内每日 toolCalls 合并）
                return aggregateWeekly(withTools)
            default:
                return Array(withTools.suffix(14))
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Text("工具调用趋势")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if display.isEmpty {
                Text("区间内无工具调用趋势数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                let maxTools = display.map(\.toolCalls).max() ?? 1
                let spacing: CGFloat = display.count > 14 ? 2 : 4
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(display) { d in
                        VStack(spacing: 2) {
                            if display.count <= 14 {
                                Text("\(d.toolCalls)")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.tokenCacheRead.opacity(0.85))
                                .frame(height: barHeight(d.toolCalls, max: maxTools))
                            if display.count <= 14 {
                                Text(String(d.date.suffix(5)))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: display.count > 14 ? 56 : 70)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 按周聚合（周一为周首），用于 range=all
    private func aggregateWeekly(_ daily: [DailyTotal]) -> [DailyTotal] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Aggregator.shanghai
        cal.firstWeekday = 2

        // (weekStartDate, [aggregated fields])
        var buckets: [String: (tokens: Int, tools: Int, msgs: Int)] = [:]
        var order: [String] = []
        for d in daily {
            guard let date = formatter.date(from: d.date) else { continue }
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            guard let weekStart = cal.date(from: comps) else { continue }
            let key = formatter.string(from: weekStart)
            if buckets[key] == nil { order.append(key) }
            var b = buckets[key] ?? (0, 0, 0)
            b.tokens += d.tokens
            b.tools += d.toolCalls
            b.msgs += d.msgs
            buckets[key] = b
        }
        return order.sorted().map { key in
            let b = buckets[key]!
            return DailyTotal(date: key, tokens: b.tokens, toolCalls: b.tools, msgs: b.msgs)
        }
    }

    private func barHeight(_ v: Int, max m: Int) -> CGFloat {
        guard m > 0 else { return 4 }
        return max(4, CGFloat(v) / CGFloat(m) * 50)
    }
}
