import SwiftUI

// MARK: - Donut Chart
//
// 环形占比图：一圈按 value 占比切分的彩色环，中心叠大数字。
// 生长动画：onAppear / 数据变化时 progress 从 0 → 1，环从 0 逐渐画满
// （easeOut 0.8s）。颜色用调用方传入（通常 Theme.modelColor）。
//
// 用法：
//   DonutChart(segments: [
//       DonutSegment(color: Theme.modelColor("glm"), value: 123456),
//       DonutSegment(color: Theme.modelColor("deepseek"), value: 45678),
//   ], centerTitle: "Top 模型", centerValue: formatTokens(total))

struct DonutSegment: Identifiable {
    let id = UUID()
    let color: Color
    let value: Double
}

struct DonutChart: View {
    let segments: [DonutSegment]
    var ringWidth: CGFloat = 13
    var centerTitle: String = ""
    var centerValue: String = ""

    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            // 背景暗轨（环的底座）
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: ringWidth)

            // 逐段画环：每段 trim(from:to:) 定位，累加起始角。
            // progress 把每段的 end 缩到 progress*end —— 环从 0 画满。
            ForEach(Array(placed.enumerated()), id: \.offset) { idx, p in
                Circle()
                    .trim(from: p.start * progress, to: p.end * progress)
                    .stroke(
                        p.color,
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
            }

            // 中心：大数字 + 标题
            VStack(spacing: 2) {
                Text(centerValue)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(centerTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .animation(.easeOut(duration: 0.8), value: progress)
        .onAppear { resetProgress() }
        .onChange(of: segments.map(\.value)) { _, _ in resetProgress() }
    }

    // MARK: - Geometry

    private struct Placed {
        let color: Color
        let start: Double
        let end: Double
    }

    /// 把所有 segment 的 value 归一化成 [0,1] 的占比区间
    private var placed: [Placed] {
        let total = segments.reduce(0.0) { $0 + $1.value }
        guard total > 0 else { return [] }
        var acc = 0.0
        return segments.map { seg in
            let start = acc / total
            acc += seg.value
            return Placed(color: seg.color, start: start, end: acc / total)
        }
    }

    /// 数据变化时重播生长动画：progress 瞬间归零，下一帧 easeOut 画满
    private func resetProgress() {
        progress = 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            withAnimation(.easeOut(duration: 0.8)) {
                progress = 1
            }
        }
    }
}
