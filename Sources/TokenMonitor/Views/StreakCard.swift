import SwiftUI

// MARK: - StreakCard
//
// 连续打卡卡片：克制版（Apple HIG 取向）。
//
// 设计原则：
//   - 不再做 Duolingo 式的橙红渐变 + 光晕（在分析工具里突兀）
//   - 火苗仍保留，但走 SF Symbol + 单一 systemOrange（不再渐变）
//   - 数字着色 .primary 让数字自身说话
//   - 进度条从橙红线性渐变 → 中性灰 + 火苗色 hint，仅"刻度"语义
//   - 0 streak 时所有橙色退为系统灰，不诱导"未打卡焦虑"
//
// streak 是跨所有时间计算的（不随 range 切换变化），永远是当前的状态。

struct StreakCard: View {
    let streak: Aggregator.StreakInfo
    @Environment(\.colorScheme) private var colorScheme

    private var streakColor: Color {
        streak.current > 0 ? Color.orange : Color.secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            // 左：当前连续天数 + 火苗（单色克制版）
            VStack(alignment: .center, spacing: 4) {
                Image(systemName: streak.current > 0 ? "flame.fill" : "flame")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(streakColor)
                    .symbolEffect(.bounce, value: streak.current)

                Text("\(streak.current)")
                    .font(Theme.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(streak.current)))
                    .animation(.easeOut(duration: 0.3), value: streak.current)

                Text("当前")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 70)

            Divider().frame(height: 50).opacity(0.25)

            // 右：历史最长 + 今日状态 + 进度条（克制版，不再橙红渐变）
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("历史最长")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(streak.longest) 天")
                        .font(Theme.Typography.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: Double(streak.longest)))
                        .animation(.easeOut(duration: 0.3), value: streak.longest)
                }
                HStack(spacing: 6) {
                    Image(systemName: streak.activeToday ? "checkmark.seal.fill" : "clock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(streak.activeToday ? Color.green : Color.secondary)
                    Text("今日")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(streak.activeToday ? "已使用" : "未开始")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(streak.activeToday ? Color.green : Color.secondary)
                }

                // 进度条：中性灰底 + 火苗色填充（克制版，仅作刻度）
                if streak.longest > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                                .fill(.quaternary.opacity(0.4))
                            RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                                .fill(streakColor.opacity(streak.current > 0 ? 0.7 : 0.0))
                                .frame(width: geo.size.width * CGFloat(streak.current) / CGFloat(streak.longest))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
