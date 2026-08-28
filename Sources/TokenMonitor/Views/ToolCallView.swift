import SwiftUI

// MARK: - Tool Call View
//
// 工具调用维度：
// - 工具调用排行（哪个模型最常调工具）
// - tool_calls / msg 比率（衡量"工具重"程度）
// - 工具调用日趋势（仅 zcode 来源有数据）

struct ToolCallView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme

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
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 16) {
                metric(label: "总调用数", value: formatNumber(viewModel.totalToolCalls), tokens: viewModel.totalToolCalls)
                metric(label: "总消息数", value: formatNumber(viewModel.totalMsgs), tokens: viewModel.totalMsgs)
                let ratio = viewModel.totalMsgs > 0 ? Double(viewModel.totalToolCalls) / Double(viewModel.totalMsgs) : 0
                metric(label: "调用/消息", value: String(format: "%.2f", ratio), tokens: Int(ratio * 100))
            }
            if !hasToolData {
                Text("当前区间内没有工具调用数据（仅 ZCode 来源会记录 tool_call_count）")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func metric(label: String, value: String, tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.Typography.metric)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: Double(tokens)))
                .animation(.easeOut(duration: 0.3), value: tokens)
            Text(label).font(Theme.Typography.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Ranking

    private var rankingCard: some View {
        let ranked = viewModel.models
            .filter { $0.toolCallCount > 0 }
            .sorted { $0.toolCallCount > $1.toolCallCount }

        return VStack(alignment: .leading, spacing: 8) {
            Text("工具调用排行")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if ranked.isEmpty {
                Text("区间内无工具调用数据")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                let maxTools = ranked.first?.toolCallCount ?? 1
                // 表头
                HStack(spacing: 8) {
                    Text("模型")
                        .font(Theme.Typography.captionMonospaced)
                        .foregroundStyle(.tertiary)
                        .frame(width: 110, alignment: .leading)
                    Text("工具调用")
                        .font(Theme.Typography.captionMonospaced)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                    Text("次数")
                        .font(Theme.Typography.captionMonospaced)
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                    Text("次/消息")
                        .font(Theme.Typography.captionMonospaced)
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                }
                Divider()
                ForEach(ranked.prefix(8)) { u in
                    let providerName = providerDisplayName(u.provider, model: u.model)
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.modelColor(u.model + u.provider)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(u.model)
                                    .font(Theme.Typography.body.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !providerName.isEmpty {
                                    Text(providerName)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous).fill(.quaternary.opacity(0.4))
                                RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                                    .fill(Theme.tokenCacheRead.opacity(0.85))
                                    .frame(width: max(4, geo.size.width * CGFloat(Double(u.toolCallCount) / Double(maxTools))))
                            }
                        }
                        .frame(height: 8)
                        Text("\(u.toolCallCount)")
                            .font(Theme.Typography.captionMonospaced)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(String(format: "%.2f", u.toolCallsPerMsg))
                            .font(Theme.Typography.captionMonospaced)
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
                if ranked.count > 8 {
                    Text("+ 其余 \(ranked.count - 8) 个模型未展示")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if display.isEmpty {
                Text("区间内无工具调用趋势数据")
                    .font(Theme.Typography.body)
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
                                    .font(Theme.Typography.captionMonospaced)
                                    .foregroundStyle(.secondary)
                            }
                            RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                                .fill(Theme.tokenCacheRead.opacity(0.85))
                                .frame(height: barHeight(d.toolCalls, max: maxTools))
                            if display.count <= 14 {
                                Text(String(d.date.suffix(5)))
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: display.count > 14 ? 56 : 70)
            }
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
        // 防御除 0 / 负数 → NaN（frame(height: nan) 触发 baseline 异常 → 切源崩溃）
        let ratio = max(0, min(Double(v) / Double(m), 1.0))
        return max(4, CGFloat(ratio) * 50)
    }
}
