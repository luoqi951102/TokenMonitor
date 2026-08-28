import SwiftUI

// MARK: - Token Monitor Theme (3.0 皮肤分发层)
//
// 3.0 起 Theme 是"当前皮肤"的静态门面：所有成员转发到
// SkinManager.shared.tokens，三套皮肤（Crystalline / Aurora / Instrument）
// 切换时全部消费点即时换装。
//
// 设计原则（沿用 2.x）：
//  1. accent 色稀缺使用 —— 只用于 Logo 渐变、ACTIVE tab 下划线、唯一 CTA
//  2. Type Scale 4 档：metric / title / body / caption
//  3. Radius 4 档嵌套阶梯：panel 22 / card 14 / control 8 / bar 4
//  4. Material 一层到底 —— panel 容器一层材质，卡片纯色 + hairline
//  5. 数据数字优先 .primary + .monospacedDigit

enum Theme {
    // MARK: - Layout（与皮肤无关的固定布局）

    static let panelWidth: CGFloat = 360
    static let panelDashboardHeight: CGFloat = 620
    static let panelTopGap: CGFloat = 12

    // MARK: - Radius Scale（4 档嵌套，与皮肤无关）

    enum Radius {
        static let panel: CGFloat = 22
        static let card: CGFloat = 14
        static let control: CGFloat = 8
        static let bar: CGFloat = 4
    }

    /// 旧名兼容
    static var panelCornerRadius: CGFloat { Radius.panel }

    // MARK: - 皮肤转发（Brand / 语义色 / 渐变 / 表面）

    private static var t: SkinTokens { SkinManager.shared.tokens }

    static var brand: Color { t.brand }
    static var brandLight: Color { t.brandLight }
    static var brandGradient: LinearGradient { t.brandGradient }
    static var chartBar: LinearGradient { t.chartBar }

    static var tokenInput: Color { t.tokenInput }
    static var tokenCacheWrite: Color { t.tokenCacheWrite }
    static var tokenCacheRead: Color { t.tokenCacheRead }
    static var tokenOutput: Color { t.tokenOutput }

    /// 状态语义色（StreakCard / 阈值着色等散落 orange/green 的收编目标）
    static var statusOK: Color { t.statusOK }
    static var statusWarn: Color { t.statusWarn }
    static var statusHot: Color { t.statusHot }

    // ---- 皮肤特性开关 ----

    static var enablesGlow: Bool { t.enablesGlow }                     // Aurora
    static var enablesBorderBeam: Bool { t.enablesBorderBeam }         // Aurora
    static var enablesThresholdColors: Bool { t.enablesThresholdColors } // Instrument
    static var density: Double { t.density }                           // Instrument 0.92

    // ---- Surfaces（深浅色 × 皮肤二维）----

    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        t.card(for: colorScheme)
    }

    static func windowBackground(for colorScheme: ColorScheme) -> Color {
        t.windowTint(for: colorScheme)
    }

    static func panelBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? t.hairline : Color.black.opacity(0.08)
    }

    static func panelShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.14)
    }

    // MARK: - Type Scale（4 档；density 用于 Instrument 紧凑感）

    enum Typography {
        private static var s: Double { SkinManager.shared.tokens.density }

        /// 大数字（KPI、悬浮窗主 token 展示）
        static var metric: Font { .system(size: 28 * s, weight: .semibold, design: .rounded) }
        /// 卡片标题 / 浮窗 header 标题
        static var title: Font { .system(size: 15 * s, weight: .semibold) }
        /// 主要文字
        static var body: Font { .system(size: 13 * s, weight: .regular) }
        /// 辅助说明
        static var caption: Font { .system(size: 11 * s, weight: .regular) }
        /// 数字增强（等宽）
        static var captionMonospaced: Font { .system(size: 11 * s, weight: .medium, design: .monospaced) }
    }

    /// 菜单栏图标尺寸
    static let menuBarIconSize = NSSize(width: 18, height: 18)

    // MARK: - Model Color Palette（与皮肤无关的模型身份色，FNV-1a 稳定哈希）

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
        var hash: UInt32 = 2166136261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return modelPalette[Int(hash % UInt32(modelPalette.count))]
    }
}
