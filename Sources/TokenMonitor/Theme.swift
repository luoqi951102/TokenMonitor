import SwiftUI

// MARK: - Token Monitor Theme
//
// 品牌色: #5B6CFF (中性 Indigo)
// 所有 UI 组件的颜色、渐变、字体统一从这里取。

enum Theme {
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 500
    static let panelDashboardHeight: CGFloat = 620
    static let panelEmptyHeight: CGFloat = 300
    static let panelCornerRadius: CGFloat = 22
    static let panelTopGap: CGFloat = 12
    static let detailPanelWidth: CGFloat = panelWidth
    static let detailPanelHeight: CGFloat = panelDashboardHeight
    static let detailPanelGap: CGFloat = 10

    // MARK: - Brand Colors

    /// 中性 Indigo #5B6CFF
    static let brand = Color(red: 0.357, green: 0.424, blue: 1.000)

    /// 浅色（渐变用）
    static let brandLight = Color(red: 0.475, green: 0.533, blue: 1.000)

    /// 深色（按压/强调）
    static let brandDark = Color(red: 0.282, green: 0.345, blue: 0.890)

    /// 品牌色半透明（弱化背景）
    static let brandFaint = Color(red: 0.357, green: 0.424, blue: 1.000, opacity: 0.08)

    // MARK: - Token 构成配色（input / cache_write / cache_read / output）
    //
    // 用于堆叠柱图、饼图、模型对比表等所有按 token 构成拆色的地方。
    static let tokenInput = Color(red: 0.357, green: 0.424, blue: 1.000)         // indigo
    static let tokenCacheWrite = Color(red: 0.980, green: 0.702, blue: 0.282)    // amber
    static let tokenCacheRead = Color(red: 0.247, green: 0.741, blue: 0.580)     // emerald
    static let tokenOutput = Color(red: 0.886, green: 0.345, blue: 0.788)        // pink

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

    // MARK: - Components

    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(white: 0.12).opacity(0.94)
            : Color(white: 0.97).opacity(0.92)
    }

    static func windowBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.15, blue: 0.18).opacity(0.88)
            : Color(red: 0.96, green: 0.98, blue: 1.0).opacity(0.90)
    }

    static func panelBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.08)
    }

    static func panelShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.28)
            : Color.black.opacity(0.18)
    }

    /// 大号数字字体（等宽）
    static let metricFont = Font.system(size: 26, weight: .bold, design: .rounded)

    /// 菜单栏图标尺寸
    static let menuBarIconSize = NSSize(width: 18, height: 18)

    // MARK: - Model Color Palette
    //
    // 模型无关的循环色板，按模型名 hash 后稳定取色，确保同一模型在不同视图颜色一致。
    private static let modelPalette: [Color] = [
        Color(red: 0.357, green: 0.424, blue: 1.000),   // indigo
        Color(red: 0.980, green: 0.702, blue: 0.282),   // amber
        Color(red: 0.247, green: 0.741, blue: 0.580),   // emerald
        Color(red: 0.886, green: 0.345, blue: 0.788),   // pink
        Color(red: 0.380, green: 0.804, blue: 0.890),   // cyan
        Color(red: 0.847, green: 0.337, blue: 0.388),   // crimson
        Color(red: 0.659, green: 0.510, blue: 0.890),   // violet
        Color(red: 0.345, green: 0.745, blue: 0.510),   // green
    ]

    static func modelColor(_ name: String) -> Color {
        let hash = abs(name.hashValue)
        return modelPalette[hash % modelPalette.count]
    }

    // MARK: - Modifier Helpers

    struct CardStyle: ViewModifier {
        @Environment(\.colorScheme) var colorScheme

        func body(content: Content) -> some View {
            content
                .padding(14)
                .background(cardBackground(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
