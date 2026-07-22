import SwiftUI

// MARK: - Token Monitor Theme
//
// 设计原则（Apple HIG 对齐）：
//  1. accent 色稀缺使用 —— 只用于 Logo 渐变、ACTIVE tab 下划线、唯一 CTA，
//     其他场景（数字、文字、圆点）一律 `.primary` / `.secondary` / `.tertiary`。
//  2. Type Scale 4 档：metric / title / body / caption，禁止散用 inline 字号。
//  3. Radius 4 档嵌套阶梯：panel 22 / card 14 / control 8 / bar 4，
//     比例规整，避免大跳—小跳—大跳的视觉不规则。
//  4. Material 一层到底 —— panel 容器一层材质，卡片用纯色 + hairline border，
//     不嵌套多层 acrylic，避免"透过镜子看窗户"的糊感。
//  5. 数据数字优先 `.primary` + `.monospacedDigit`，让数字本身说话,
//     不靠彩色背书。

enum Theme {
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 500
    static let panelDashboardHeight: CGFloat = 620
    static let panelEmptyHeight: CGFloat = 300
    static let panelTopGap: CGFloat = 12
    static let detailPanelWidth: CGFloat = panelWidth
    static let detailPanelHeight: CGFloat = panelDashboardHeight
    static let detailPanelGap: CGFloat = 10

    // MARK: - Radius Scale（4 档嵌套）
    //
    // panel: 容器层浮窗/主面板外圆角
    // card:  KPI / Streak / Trend 卡片
    // control: 按钮、tab、chip 等
    // bar:  数据柱、进度条
    enum Radius {
        static let panel: CGFloat = 22
        static let card: CGFloat = 14
        static let control: CGFloat = 8
        static let bar: CGFloat = 4
    }

    // 旧名兼容（迁移期内逐步替换，最后删）
    static let panelCornerRadius: CGFloat = Radius.panel

    // MARK: - Brand Colors
    //
    // #4E5BD6 —— 比原 #5B6CFF 降饱和 8% 的 indigo，更接近 Apple System Indigo
    // 在 light / dark vibrancy 材质叠加上不会偏紫/偏品红漂移。
    static let brand = Color(red: 0.306, green: 0.357, blue: 0.839)
    static let brandLight = Color(red: 0.420, green: 0.475, blue: 0.920)
    static let brandDark = Color(red: 0.239, green: 0.290, blue: 0.745)
    static let brandFaint = Color(red: 0.306, green: 0.357, blue: 0.839, opacity: 0.08)

    // MARK: - Token 构成配色（input / cache_write / cache_read / output）
    //
    // 用于堆叠柱图、饼图、模型对比表等按 token 构成拆色的地方。
    // 用作"语义色"，比品牌色饱和更高是合理用法（区分输入 vs 输出）。
    static let tokenInput = Color(red: 0.306, green: 0.357, blue: 0.839)        // indigo（与 brand 同色，input 是主流量）
    static let tokenCacheWrite = Color(red: 0.945, green: 0.694, blue: 0.294)   // amber
    static let tokenCacheRead = Color(red: 0.247, green: 0.717, blue: 0.561)    // emerald
    static let tokenOutput = Color(red: 0.847, green: 0.337, blue: 0.749)       // pink

    // MARK: - Gradients

    static let brandGradient = LinearGradient(
        colors: [brand, brandLight],
        startPoint: .leading, endPoint: .trailing
    )

    static let brandGradientVertical = LinearGradient(
        colors: [brand, brandLight],
        startPoint: .top, endPoint: .bottom
    )

    /// 图表柱体渐变
    static let chartBar = LinearGradient(
        colors: [brand.opacity(0.85), brandLight.opacity(0.45)],
        startPoint: .bottom, endPoint: .top
    )

    // MARK: - Surfaces

    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        // 卡片用纯色，不再叠 acrylic；让 panel 容器承担材质层
        colorScheme == .dark
            ? Color(white: 0.16).opacity(0.72)
            : Color(white: 0.97).opacity(0.92)
    }

    static func windowBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.88)
            : Color(red: 0.97, green: 0.98, blue: 1.0).opacity(0.90)
    }

    static func panelBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    static func panelShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.28)
            : Color.black.opacity(0.14)
    }

    // MARK: - Type Scale（4 档）
    //
    // 收敛到 metric / title / body / caption 四个尺寸，
    // 禁止在 View 里直接写 size: 9 / 11 / 13 / 14 这种散值。
    enum Typography {
        /// 大数字（KPI、悬浮窗主 token 展示）
        static let metric = Font.system(size: 28, weight: .semibold, design: .rounded)
        /// 卡片标题 / 浮窗 header 标题
        static let title = Font.system(size: 15, weight: .semibold)
        /// 主要文字（model 名、菜单项、按钮文字）
        static let body = Font.system(size: 13, weight: .regular)
        /// 辅助说明（model provider 后缀、token 数字、范围标签）
        static let caption = Font.system(size: 11, weight: .regular)
        /// 数字增强（KPI value、metric 等）—— caption 数字版
        static let captionMonospaced = Font.system(size: 11, weight: .medium, design: .monospaced)
    }

    /// 旧名兼容（迁移期内逐步替换，最后删）
    static let metricFont = Typography.metric

    /// 菜单栏图标尺寸
    static let menuBarIconSize = NSSize(width: 18, height: 18)

    // MARK: - Model Color Palette
    //
    // 模型无关的循环色板，按模型名 **FNV-1a 稳定哈希** 后取色，
    // 保证同一 model 跨进程启动颜色稳定（不再依赖 Swift hashValue，避免漂移）。
    private static let modelPalette: [Color] = [
        Color(red: 0.306, green: 0.357, blue: 0.839),   // indigo
        Color(red: 0.945, green: 0.694, blue: 0.294),   // amber
        Color(red: 0.247, green: 0.717, blue: 0.561),   // emerald
        Color(red: 0.847, green: 0.337, blue: 0.749),   // pink
        Color(red: 0.380, green: 0.741, blue: 0.866),   // cyan
        Color(red: 0.812, green: 0.329, blue: 0.376),   // crimson
        Color(red: 0.596, green: 0.475, blue: 0.843),   // violet
        Color(red: 0.345, green: 0.717, blue: 0.494),   // green
    ]

    static func modelColor(_ name: String) -> Color {
        // FNV-1a 32-bit 稳定哈希，避免 Swift hashValue 每进程漂移
        var hash: UInt32 = 2166136261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return modelPalette[Int(hash % UInt32(modelPalette.count))]
    }

    // MARK: - Modifier Helpers

    struct CardStyle: ViewModifier {
        @Environment(\.colorScheme) var colorScheme

        func body(content: Content) -> some View {
            content
                .padding(14)
                .background(cardBackground(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    struct IconCircle: View {
        let color: Color

        var body: some View {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(color)
        }
    }
}

// MARK: - View Extension

extension View {
    func themeCard() -> some View {
        modifier(Theme.CardStyle())
    }

    func themeTint() -> some View {
        self.tint(Theme.brand)
    }
}
