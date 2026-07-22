import SwiftUI

// MARK: - ProjectRankingView
//
// 项目维度排行：Apple 工具感（克制版）。
//
// 设计原则：
//   - 去掉金/银/铜奖牌色（web 风，反 Apple HIG）
//   - 排名前缀改 #1 / #2 / #3 用统一 .secondary 色
//   - 横条改纯色 stroke 色（不再 amber→emerald 渐变）
//   - 项目 icon folder.fill 退为 .tertiary 灰
//   - Token 数 + 占比右对齐 monospaced，让视线先落在数字
//   - 卡片材质从 .regularMaterial → cardBackground 纯色与主面板呼应

struct ProjectRankingView: View {
    let projects: [Aggregator.ProjectStat]
    var maxDisplay: Int = 5
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text("项目维度")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(projects.count) 个项目")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }

            if projects.isEmpty {
                Text("区间内无数据")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                let maxTokens = projects.first?.tokens ?? 1
                let totalTokens = projects.reduce(0) { $0 + $1.tokens }
                VStack(spacing: 6) {
                    ForEach(Array(projects.prefix(maxDisplay).enumerated()), id: \.element.id) { idx, p in
                        projectRow(p, rank: idx + 1, maxTokens: maxTokens, totalTokens: totalTokens)
                    }
                }
                if projects.count > maxDisplay {
                    Text("+ 其余 \(projects.count - maxDisplay) 个项目")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func projectRow(_ p: Aggregator.ProjectStat, rank: Int, maxTokens: Int, totalTokens: Int) -> some View {
        let pct = maxTokens > 0 ? Double(p.tokens) / Double(maxTokens) : 0
        let share = totalTokens > 0 ? Double(p.tokens) / Double(totalTokens) * 100 : 0
        let rowAccent = Theme.modelColor(p.project) // 复用 model 色板，让每个项目有稳定识别色

        return HStack(spacing: 8) {
            // 排名：单色 .secondary，不再金银铜
            Text("#\(rank)")
                .font(Theme.Typography.captionMonospaced.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)

            // 项目图标 + 名字
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(rowAccent.opacity(0.85))
                Text(lastPathComponent(p.project))
                    .font(Theme.Typography.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 横条（单色，不再渐变）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                    RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                        .fill(rowAccent.opacity(0.85))
                        .frame(width: max(4, geo.size.width * pct))
                }
            }
            .frame(width: 60, height: 6)

            // 占比 + token 数  右对齐 monospaced
            VStack(alignment: .trailing, spacing: 0) {
                Text(formatTokens(p.tokens))
                    .font(Theme.Typography.captionMonospaced.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(String(format: "%.0f%%", share))
                    .font(Theme.Typography.captionMonospaced)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 20)
    }
}
