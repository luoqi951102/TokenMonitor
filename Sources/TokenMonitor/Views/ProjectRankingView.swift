import SwiftUI

// MARK: - ProjectRankingView
//
// 项目维度排行：看用户在哪些项目用 LLM 多。
// - 标题 + 总项目数
// - Top N 横条（路径转 ~ 格式，截断显示）
// - 文件夹图标 + 项目名 + 横条 + token 数 + 占比百分比

struct ProjectRankingView: View {
    let projects: [Aggregator.ProjectStat]
    var maxDisplay: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tokenCacheWrite)
                Text("项目维度")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(projects.count) 个项目")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if projects.isEmpty {
                Text("区间内无数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                let maxTokens = projects.first?.tokens ?? 1
                let totalTokens = projects.reduce(0) { $0 + $1.tokens }
                ForEach(Array(projects.prefix(maxDisplay).enumerated()), id: \.element.id) { idx, p in
                    projectRow(p, rank: idx + 1, maxTokens: maxTokens, totalTokens: totalTokens)
                }
                if projects.count > maxDisplay {
                    Text("+ 其余 \(projects.count - maxDisplay) 个项目")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func projectRow(_ p: Aggregator.ProjectStat, rank: Int, maxTokens: Int, totalTokens: Int) -> some View {
        let pct = maxTokens > 0 ? Double(p.tokens) / Double(maxTokens) : 0
        let share = totalTokens > 0 ? Double(p.tokens) / Double(totalTokens) * 100 : 0
        // 排名颜色（金银铜）
        let rankColor: Color = {
            switch rank {
            case 1: return .yellow
            case 2: return .gray
            case 3: return .orange.opacity(0.8)
            default: return .secondary
            }
        }()

        return HStack(spacing: 8) {
            // 排名
            Text("#\(rank)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(rankColor)
                .frame(width: 22, alignment: .center)

            // 项目图标 + 名字（只显示最后一层目录名）
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tokenCacheWrite.opacity(0.8))
                Text(lastPathComponent(p.project))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 130, alignment: .leading)

            // 横条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary.opacity(0.4))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Theme.tokenCacheWrite, Theme.tokenCacheRead],
                                startPoint: .leading, endPoint: .trailing
                            ).opacity(0.85)
                        )
                        .frame(width: max(4, geo.size.width * pct))
                }
            }
            .frame(height: 8)

            // 占比 + token 数
            VStack(alignment: .trailing, spacing: 0) {
                Text(formatTokens(p.tokens))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(String(format: "%.0f%%", share))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 20)
    }
}
