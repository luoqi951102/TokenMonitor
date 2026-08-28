import SwiftUI

// MARK: - 皮肤系统 (3.0)
//
// 三套设计 token（对齐 design/v3-mockups.html 三方案）：
//   crystalline — Raycast 原生暗色：近黑冷调阶梯 + hairline 分层，零辉光零流光
//   aurora      — Linear 辉光玻璃：深紫黑 + 彩色光斑呼吸 + 边框流光 + 环发光加强
//   instrument  — stats 仪表密度：完全跟随系统深浅色 + 阈值三色着色 + 高密度紧凑
//
// 架构：Theme 的静态 API 保持不变（42+ 处 Theme.brand 等消费点零改动），
// Theme 内部转发到 SkinManager.shared.tokens。切皮肤 = 换 tokens 实例，
// SkinManager 是 ObservableObject，根视图观察它即可整树重渲即时生效。

// MARK: - Skin enum

enum Skin: String, CaseIterable, Identifiable {
    case crystalline
    case aurora
    case instrument

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crystalline: return "Crystalline · 原生暗色"
        case .aurora:      return "Aurora · 辉光玻璃"
        case .instrument:  return "Instrument · 仪表密度"
        }
    }

    var icon: String {
        switch self {
        case .crystalline: return "square.grid.2x2"
        case .aurora:      return "sparkles"
        case .instrument:  return "speedometer"
        }
    }

    var tokens: SkinTokens {
        switch self {
        case .crystalline: return CrystallineSkin()
        case .aurora:      return AuroraSkin()
        case .instrument:  return InstrumentSkin()
        }
    }
}

// MARK: - SkinTokens 协议

protocol SkinTokens {
    // ---- 表面 3 级（深浅色叠加；面板底 = surface，卡片 = card）----
    func surface(for scheme: ColorScheme) -> Color
    func card(for scheme: ColorScheme) -> Color
    func windowTint(for scheme: ColorScheme) -> Color   // Settings 等次级窗口底
    var hairline: Color { get }                          // 1px 边框（深色主导的固定值）

    // ---- 品牌 ----
    var brand: Color { get }
    var brandLight: Color { get }
    var brandGradient: LinearGradient { get }
    var chartBar: LinearGradient { get }

    // ---- Token 构成语义色 ----
    var tokenInput: Color { get }
    var tokenCacheWrite: Color { get }
    var tokenCacheRead: Color { get }
    var tokenOutput: Color { get }

    // ---- 状态语义（Instrument 阈值着色用；其他皮肤收编散落 orange/green）----
    var statusOK: Color { get }
    var statusWarn: Color { get }
    var statusHot: Color { get }

    // ---- 特性开关（皮肤标志性差异）----
    var enablesGlow: Bool { get }             // 辉光光斑 + 环发光加强
    var enablesBorderBeam: Bool { get }       // 卡片边框流光
    var enablesThresholdColors: Bool { get }  // 热力条/状态绿→黄→红阈值映射
    var density: Double { get }               // 字号密度缩放（<1 = 紧凑）
}

// MARK: - 工具：hex → Color

private func skinColor(_ hex: UInt32, opacity: Double = 1.0) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255.0,
        green: Double((hex >> 8) & 0xFF) / 255.0,
        blue: Double(hex & 0xFF) / 255.0,
        opacity: opacity
    )
}

// MARK: - Crystalline（Raycast 原生暗色）
//
// 4 级近黑冷调阶梯: canvas #07080a → surface #0d0d0d → card #121212
// 层级靠"上浮一档 + hairline white 8%"，零阴影零辉光。
// 语义色: blue #57c1ff / green #59d499 / yellow #ffc533 / red #ff6161（只做标点）。

struct CrystallineSkin: SkinTokens {
    // Raycast 语义色
    private let blue   = skinColor(0x57C1FF)
    private let green  = skinColor(0x59D499)
    private let yellow = skinColor(0xFFC533)
    private let red    = skinColor(0xFF6161)

    func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x0D0D0D) : skinColor(0xF5F5F7)
    }
    func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x121212) : .white
    }
    func windowTint(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x0A0A0A) : skinColor(0xEDEDF0)
    }
    var hairline: Color { Color.white.opacity(0.08) }

    var brand: Color { skinColor(0x6E7BFF) }   // 比 2.x indigo 略亮更"冷"
    var brandLight: Color { skinColor(0x9BA6FF) }
    var brandGradient: LinearGradient {
        LinearGradient(colors: [brand, brandLight], startPoint: .leading, endPoint: .trailing)
    }
    var chartBar: LinearGradient {
        LinearGradient(colors: [brand.opacity(0.85), brandLight.opacity(0.45)],
                       startPoint: .bottom, endPoint: .top)
    }

    var tokenInput: Color { blue }
    var tokenCacheWrite: Color { yellow }
    var tokenCacheRead: Color { green }
    var tokenOutput: Color { skinColor(0xFF7AB8) }

    var statusOK: Color { green }
    var statusWarn: Color { yellow }
    var statusHot: Color { red }

    var enablesGlow: Bool { false }
    var enablesBorderBeam: Bool { false }
    var enablesThresholdColors: Bool { false }
    var density: Double { 1.0 }
}

// MARK: - Aurora（Linear 辉光玻璃）
//
// 深紫黑 #0a0a0f 底 + 彩色光斑呼吸 + 卡片玻璃受光边缘 + 边框流光。
// brand 用紫罗兰 #7C5CFF（mockup 主渐变色）。

struct AuroraSkin: SkinTokens {
    func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x12101E) : skinColor(0xF2F0FA)
    }
    func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x1B1830, opacity: 0.72) : .white.opacity(0.9)
    }
    func windowTint(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x0A0A0F) : skinColor(0xE9E6F5)
    }
    var hairline: Color { Color.white.opacity(0.09) }

    var brand: Color { skinColor(0x7C5CFF) }
    var brandLight: Color { skinColor(0x9D85FF) }
    var brandGradient: LinearGradient {
        LinearGradient(colors: [skinColor(0x7C5CFF), skinColor(0x4D6BFE)],
                       startPoint: .leading, endPoint: .trailing)
    }
    var chartBar: LinearGradient {
        LinearGradient(colors: [skinColor(0x7C5CFF, opacity: 0.85), skinColor(0x4D6BFE, opacity: 0.45)],
                       startPoint: .bottom, endPoint: .top)
    }

    var tokenInput: Color { skinColor(0x4D9FFF) }
    var tokenCacheWrite: Color { skinColor(0xFFB340) }
    var tokenCacheRead: Color { skinColor(0x59D499) }
    var tokenOutput: Color { skinColor(0xFF7AB8) }

    var statusOK: Color { skinColor(0x59D499) }
    var statusWarn: Color { skinColor(0xFFC533) }
    var statusHot: Color { skinColor(0xFF6161) }

    var enablesGlow: Bool { true }
    var enablesBorderBeam: Bool { true }
    var enablesThresholdColors: Bool { false }
    var density: Double { 1.0 }
}

// MARK: - Instrument（stats 仪表密度）
//
// 完全跟随系统外观（深浅色对称实现），高密度紧凑（density 0.92），
// 阈值三色着色（绿→黄→红）启用。品牌色用 stats 风格翠绿。

struct InstrumentSkin: SkinTokens {
    func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x1C1C1E) : skinColor(0xF2F2F7)
    }
    func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x2C2C2E) : .white
    }
    func windowTint(for scheme: ColorScheme) -> Color {
        scheme == .dark ? skinColor(0x161618) : skinColor(0xE5E5EA)
    }
    var hairline: Color { Color.primary.opacity(0.10) }

    var brand: Color { skinColor(0x30D158) }   // stats 翠绿
    var brandLight: Color { skinColor(0x66E383) }
    var brandGradient: LinearGradient {
        LinearGradient(colors: [skinColor(0x30D158), skinColor(0x66E383)],
                       startPoint: .leading, endPoint: .trailing)
    }
    var chartBar: LinearGradient {
        LinearGradient(colors: [skinColor(0x30D158, opacity: 0.85), skinColor(0x66E383, opacity: 0.45)],
                       startPoint: .bottom, endPoint: .top)
    }

    // Apple 系统语义色（iOS/macOS systemGreen 等）
    var tokenInput: Color { skinColor(0x0A84FF) }
    var tokenCacheWrite: Color { skinColor(0xFF9F0A) }
    var tokenCacheRead: Color { skinColor(0x30D158) }
    var tokenOutput: Color { skinColor(0xBF5AF2) }

    var statusOK: Color { skinColor(0x30D158) }
    var statusWarn: Color { skinColor(0xFFD60A) }
    var statusHot: Color { skinColor(0xFF453A) }

    var enablesGlow: Bool { false }
    var enablesBorderBeam: Bool { false }
    var enablesThresholdColors: Bool { true }
    var density: Double { 0.92 }
}

// MARK: - SkinManager
//
// 故意不加 @MainActor：Theme 的 static 访问器（Theme.brand 等）在任意上下文
// 被调（含 TimelineView 闭包、后台 Task），若隔离到 MainActor 会让全部消费点
// 编译报错。skin 值本身只是普通 enum，UserDefaults 读写线程安全；
// @Published 的 UI 通知照常在主线程触发。

final class SkinManager: ObservableObject {
    static let shared = SkinManager()
    static let defaultsKey = "theme_skin"

    @Published var skin: Skin {
        didSet {
            guard oldValue != skin else { return }
            UserDefaults.standard.set(skin.rawValue, forKey: Self.defaultsKey)
        }
    }

    var tokens: SkinTokens { skin.tokens }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        self.skin = Skin(rawValue: raw ?? "") ?? .crystalline
    }

    /// 循环切换（header 按钮用）
    func cycle() {
        let all = Skin.allCases
        guard let idx = all.firstIndex(of: skin) else { return }
        skin = all[(idx + 1) % all.count]
    }
}
