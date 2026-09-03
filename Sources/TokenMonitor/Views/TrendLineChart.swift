import SwiftUI

// MARK: - TrendLineChart
//
// 统一趋势折线图（浮窗 miniTrend + 主面板 trendCard 共用）：
//   - 平滑折线（二次贝塞尔中点法）
//   - 线下 brand 渐变填充
//   - 末端（最新点）accent dot
//   - 可选峰值呼吸点（TimelineView 驱动）与当前位置点（今日 0-24 档）
//   - 全零数据画基线虚线；稀疏数据（非零 <3）每点画 dot 方便定位
//
// 原生 SwiftUI Path 渲染（非位图缩放），文字/线条清晰。

struct TrendLineChart: View {
    let values: [Double]
    var lineColor: Color = Theme.brand
    var lineLightColor: Color = Theme.brandLight
    var fillOpacity: Double = 0.22
    var peakIndex: Int? = nil      // 峰值呼吸点（今日 0-24 档用）
    var nowIndex: Int? = nil       // 当前小时点（今日档用）
    var breathe: Bool = false      // 是否开启峰值呼吸动画

    private var maxV: Double {
        let m = values.max() ?? 0
        return m > 0 ? m : 1
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let allZero = values.allSatisfy { $0 == 0 }
            let pts = chartPoints(w: w, h: h)

            ZStack {
                // 全零: 基线虚线
                if allZero {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                } else {
                    // 渐变填充
                    fillPath(points: pts, w: w, h: h)
                        .fill(
                            LinearGradient(
                                colors: [lineColor.opacity(fillOpacity), Color.clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    // 折线
                    linePath(points: pts, w: w, h: h)
                        .stroke(
                            LinearGradient(colors: [lineColor, lineLightColor],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                        )
                    // 峰值呼吸点
                    if let pk = peakIndex, pk < pts.count, breathe {
                        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                            let phase = ctx.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 2.0) / 2.0
                            Circle()
                                .fill(lineColor)
                                .frame(width: 4, height: 4)
                                .position(pts[pk])
                                .opacity(0.4 + 0.6 * phase)
                        }
                    }
                    // 当前小时点
                    if let now = nowIndex, now < pts.count {
                        Circle()
                            .fill(lineColor.opacity(0.65))
                            .frame(width: 4, height: 4)
                            .position(x: pts[now].x, y: h - 2)
                    }
                    // 末端点（最新值）
                    if let last = pts.last, showEndDot {
                        Circle()
                            .fill(lineColor)
                            .frame(width: 4.5, height: 4.5)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                            .position(last)
                    }
                    // 稀疏数据: 每个非零点点 dot
                    if nonZeroCount < 3 {
                        ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                            if values[i] > 0 {
                                Circle()
                                    .fill(lineColor)
                                    .frame(width: 3, height: 3)
                                    .position(p)
                            }
                        }
                    }
                }
            }
        }
    }

    private var showEndDot: Bool { !values.isEmpty }
    private var nonZeroCount: Int { values.filter { $0 > 0 }.count }

    /// 数据点坐标（y 翻转，顶部留 4pt 呼吸点空间）
    private func chartPoints(w: CGFloat, h: CGFloat) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let n = values.count
        let stepX = n > 1 ? w / CGFloat(n - 1) : w / 2
        return values.enumerated().map { i, v in
            let x = n > 1 ? CGFloat(i) * stepX : w / 2
            let y = h - (CGFloat(v / maxV)) * (h - 6) - 2
            return CGPoint(x: x, y: y)
        }
    }

    /// 平滑折线：二次贝塞尔（相邻中点为端点，数据点为控制点）
    private func linePath(points: [CGPoint], w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        if points.count == 1 {
            p.addLine(to: first)
            return p
        }
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
            p.addQuadCurve(to: mid, control: prev)
        }
        if let last = points.last { p.addLine(to: last) }
        return p
    }

    /// 线下渐变填充（折线闭合到基线）
    private func fillPath(points: [CGPoint], w: CGFloat, h: CGFloat) -> Path {
        var p = linePath(points: points, w: w, h: h)
        guard let first = points.first, let last = points.last else { return p }
        p.addLine(to: CGPoint(x: last.x, y: h))
        p.addLine(to: CGPoint(x: first.x, y: h))
        p.closeSubpath()
        return p
    }
}
