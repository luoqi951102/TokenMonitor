import SwiftUI

// MARK: - Model Comparison View
//
// 在主面板作为 tab 展示：
// - 全模型表（input / cache_write / cache_read / output / total / msgs / tools）
// - 堆叠柱状图：各模型 token 构成对比
// - 占比横向条
//
// 模型无关：以日志原样 model 字符串显示。

struct ModelComparisonView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tableCard
            compositionCard
        }
    }

    // MARK: - Table

    private var tableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("模型对比")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.models.count) 个模型")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if viewModel.models.isEmpty {
                Text("区间内无数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                // 表头
                HStack(spacing: 4) {
                    Text("模型").font(.system(size: 9)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                    Text("In").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing)
                    Text("CWr").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing)
                    Text("CRd").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing)
                    Text("Out").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing)
                    Text("Msgs").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 32, alignment: .trailing)
                }
                Divider()
                // 表体（最多展示 8 个，避免面板溢出）
                ForEach(viewModel.models.prefix(8)) { usage in
                    modelRow(usage)
                }
                if viewModel.models.count > 8 {
                    Text("+ 其余 \(viewModel.models.count - 8) 个模型未展示")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func modelRow(_ u: ModelUsage) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(Theme.modelColor(u.model)).frame(width: 6, height: 6)
                Text(u.model).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(u.inputTokens)
            cell(u.cacheCreationTokens)
            cell(u.cacheReadTokens)
            cell(u.outputTokens)
            cell(u.msgCount)
        }
        .padding(.vertical, 1)
    }

    private func cell(_ v: Int) -> some View {
        Text(formatTokens(v))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    // MARK: - Composition (堆叠柱图)

    private var compositionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token 构成对比")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if viewModel.models.isEmpty {
                Text("无数据").font(.caption2).foregroundStyle(.tertiary)
            } else {
                let maxTotal = viewModel.models.map(\.totalTokens).max() ?? 1
                ForEach(viewModel.models.prefix(6)) { u in
                    compositionBar(u, maxTotal: maxTotal)
                }
            }

            legend
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func compositionBar(_ u: ModelUsage, maxTotal: Int) -> some View {
        let total = max(1, u.totalTokens)
        let pct = Double(u.totalTokens) / Double(max(maxTotal, 1))
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(u.model)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(formatTokens(u.totalTokens))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    seg(Theme.tokenInput, frac: Double(u.inputTokens) / Double(total), full: geo.size.width * pct)
                    seg(Theme.tokenCacheWrite, frac: Double(u.cacheCreationTokens) / Double(total), full: geo.size.width * pct)
                    seg(Theme.tokenCacheRead, frac: Double(u.cacheReadTokens) / Double(total), full: geo.size.width * pct)
                    seg(Theme.tokenOutput, frac: Double(u.outputTokens) / Double(total), full: geo.size.width * pct)
                }
            }
            .frame(height: 8)
        }
    }

    private func seg(_ color: Color, frac: Double, full: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, full * frac))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem("In", Theme.tokenInput)
            legendItem("CWr", Theme.tokenCacheWrite)
            legendItem("CRd", Theme.tokenCacheRead)
            legendItem("Out", Theme.tokenOutput)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
