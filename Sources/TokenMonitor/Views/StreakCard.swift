import SwiftUI

// MARK: - StreakCard
//
// 连续打卡卡片：游戏化激励。
// 显示当前连续天数（大数字 + 火苗）+ 历史最长 + 今日是否已用。
// streak 是跨所有时间计算的（不随 range 切换变化），永远是当前的状态。

struct StreakCard: View {
    let streak: Aggregator.StreakInfo

    var body: some View {
        HStack(spacing: 12) {
            // 左：当前连续天数 + 火苗
            VStack(alignment: .center, spacing: 2) {
                ZStack {
                    // 火苗光晕
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [streak.current > 0 ? .orange.opacity(0.35) : .gray.opacity(0.18), .clear],
                                center: .center,
                                startRadius: 2,
                                endRadius: 22
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: streak.current > 0 ? "flame.fill" : "flame")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(
                            streak.current > 0
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [.orange, .red],
                                    startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color.gray.opacity(0.5))
                        )
                        .symbolEffect(.bounce, value: streak.current)
                }

                Text("\(streak.current)")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(streak.current > 0 ? .orange : .secondary)
                Text("当前")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 70)

            Divider().frame(height: 50).opacity(0.3)

            // 右：历史最长 + 今日状态
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                    Text("历史最长")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(streak.longest) 天")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 6) {
                    Image(systemName: streak.activeToday ? "checkmark.seal.fill" : "clock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(streak.activeToday ? .green : .gray)
                    Text("今日")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(streak.activeToday ? "已使用" : "未开始")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(streak.activeToday ? Color.green : Color.secondary.opacity(0.6))
                }
                // 进度提示：当前 / 历史最长 的进度条
                if streak.longest > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary.opacity(0.4))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    LinearGradient(
                                        colors: [.orange, .red],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * CGFloat(streak.current) / CGFloat(streak.longest))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
