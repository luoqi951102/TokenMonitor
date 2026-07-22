import Foundation

// MARK: - Token Monitor Data Models
//
// 模型无关：不预设任何 provider/model，所有模型字符串原样保留。
// 来源（source）区分 Claude Code 与 ZCode。
// 不含费用/余额字段。

/// 数据来源
enum UsageSource: String, Codable, CaseIterable {
    case claude   // ~/.claude/projects/*/*.jsonl 经 cc-usage 同步
    case zcode    // ~/.zcode/cli/db/db.sqlite 经 cc-usage 同步

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .zcode:  return "ZCode"
        }
    }
}

/// 时间范围
enum UsageRange: String, Codable, CaseIterable {
    case today
    case week
    case month
    case all

    var displayName: String {
        switch self {
        case .today: return "今日"
        case .week:  return "本周"
        case .month: return "本月"
        case .all:   return "全部"
        }
    }
}

/// 单个 (source, model[, provider]) 维度的用量汇总
struct ModelUsage: Codable, Identifiable, Equatable {
    var id: String {
        if provider.isEmpty {
            return "\(source)/\(model)"
        }
        return "\(source)/\(provider)/\(model)"
    }
    let model: String                  // 原样日志字符串，如 "glm-5.2"、"claude-sonnet-4-5"
    let source: String                 // "claude" | "zcode"
    let provider: String               // provider_id（claude 日志为空，zcode 来自 model_usage.provider_id）
    let inputTokens: Int               // 输入 token
    let cacheCreationTokens: Int       // 缓存写入
    let cacheReadTokens: Int           // 缓存命中
    let outputTokens: Int              // 输出 token
    let totalContextTokens: Int        // = input + cache_creation + cache_read（不含 output）
    let msgCount: Int                  // 消息/请求次数
    let toolCallCount: Int             // 工具调用次数（Claude 日志通常为 0）

    /// 总 token（含输出，用于"消耗总量"展示）
    var totalTokens: Int {
        totalContextTokens + outputTokens
    }

    /// 工具调用密度（每次消息平均工具调用数）
    var toolCallsPerMsg: Double {
        guard msgCount > 0 else { return 0 }
        return Double(toolCallCount) / Double(msgCount)
    }

    /// 显示名：带 provider 后缀（如果有多 provider）
    /// 例如 "GLM-5.2 · 智谱官方" / "glm-52-w4a8-kv · 词元之芯·Token工厂"
    var displayWithProvider: String {
        let p = providerDisplayName(provider, model: model)
        return p.isEmpty ? model : "\(model) · \(p)"
    }

    enum CodingKeys: String, CodingKey {
        case model, source, provider
        case inputTokens = "input_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case outputTokens = "output_tokens"
        case totalContextTokens = "total_context_tokens"
        case msgCount = "msg_count"
        case toolCallCount = "tool_call_count"
    }
}

/// 一天的总量（用于趋势图）
struct DailyTotal: Codable, Identifiable, Equatable {
    var id: String { date }
    let date: String                   // "2026-07-20"
    let tokens: Int                    // 当日总 token
    let toolCalls: Int                 // 当日工具调用
    let msgs: Int                      // 当日消息数
}

/// 小时分布
struct HourlyBucket: Codable, Identifiable, Equatable {
    var id: Int { hour }
    let hour: Int                      // 0-23
    let tokens: Int
    let msgs: Int
}

// MARK: - Widget Snapshot (App Group 共享给 Widget Extension)
//
// 只存 widget 需要的最小字段，不含 API key、不含费用。

struct WidgetSnapshot: Codable {
    let generatedAt: Date
    let range: String                  // UsageRange.rawValue
    let source: String                 // UsageSource.rawValue 或 "all"
    let totalTokens: Int
    let totalToolCalls: Int
    let totalMsgs: Int
    let topModels: [ModelUsage]        // 取 top N
    let daily: [DailyTotal]            // 最近 N 天（用于 Large widget 迷你趋势）
    let lastSyncAt: Date?              // 上次 cc-usage sync 时间
}

// MARK: - Helpers

/// 整数千位分隔
func formatNumber(_ number: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
}

/// token 简短格式：1.2K / 3.4M / 5.6B
func formatTokens(_ tokens: Int) -> String {
    let v = Double(tokens)
    if v >= 1_000_000_000 {
        return String(format: "%.2fB", v / 1_000_000_000)
    }
    if v >= 1_000_000 {
        return String(format: "%.2fM", v / 1_000_000)
    }
    if v >= 1_000 {
        return String(format: "%.1fK", v / 1_000)
    }
    return "\(tokens)"
}

/// 项目名简化：只取最后一层目录名。
/// 处理三种格式：
///   - "~/work/future/token-usage-tool" → "token-usage-tool"
///   - "-Users-luoqi-work-token-count"  → "token-count"（Claude session 路径格式）
///   - "/Users/luoqi/foo/bar"           → "bar"
///   - "~"                              → "~"
///   - "(unknown)" / 空                 → "(unknown)"
func lastPathComponent(_ raw: String) -> String {
    if raw.isEmpty || raw == "(unknown)" { return "(unknown)" }
    if raw == "~" { return "~" }

    // Claude session 风格：-Users-luoqi-xxx-yyy（连字符分隔）
    if raw.hasPrefix("-") && !raw.contains("/") {
        let parts = raw.split(separator: "-").map(String.init)
        // 过滤掉 Users/luoqi 等已知前缀段，取最后一个有意义的段
        let meaningful = parts.filter { !$0.isEmpty }
        return meaningful.last ?? raw
    }

    // 标准路径：取最后一段
    let parts = raw.split(separator: "/").map(String.init)
    return parts.last ?? raw
}

/// provider_id 转可读名。
///
/// ZCode 的 provider_id 有几种格式：
///   - "builtin:bigmodel-coding-plan" → "智谱官方"
///   - "builtin:xxx"                  → "官方 xxx"
///   - UUID（如 "7aff2f39-..."）       → 走内置 UUID 映射表
///   - 空（Claude 日志没 provider）    → 走 model 维度推断
///
/// 内置 UUID 映射（用户提供的）：
///   7aff2f39-217e-4f1c-82f6-b8e857a9be22 → 浙算 MaaS
///   e42dedab-efa4-4e63-9de5-8138073a2383 → 词元之芯·Token工厂
///   f2b1acc3-7c19-4a25-a6b5-f9783a0d91f9 → 火山引擎
///
/// model 维度推断（用于 Claude 日志无 provider 场景）：
///   - "glm-52-w4a8-kv"  → 词元之芯·Token工厂
///   - "glm-52-w4a8-kvp" → 词元之芯·Token工厂
///   - "qwen3*"           → 通义千问
///   - "doubao-*"         → 豆包
///   - "deepseek-v4-pro"  → 火山引擎
///   - "minimax-*"        → Minimax
///
/// 如果用户在 Settings 里配置了 provider 别名映射，优先用别名（按完整 key 匹配）。
func providerDisplayName(_ provider: String, model: String = "") -> String {
    // 用户自定义别名（存 UserDefaults：provider_alias_<key> -> 名字）
    let aliasKeyModel = "provider_alias_\(provider)__\(model)"
    if !provider.isEmpty, let alias = UserDefaults.standard.string(forKey: aliasKeyModel), !alias.isEmpty {
        return alias
    }
    let aliasKey = "provider_alias_\(provider)"
    if !provider.isEmpty, let alias = UserDefaults.standard.string(forKey: aliasKey), !alias.isEmpty {
        return alias
    }

    // 1. provider 已知 → 内置映射
    if !provider.isEmpty {
        if provider.hasPrefix("builtin:") {
            let suffix = String(provider.dropFirst("builtin:".count))
            switch suffix {
            case "bigmodel-coding-plan": return "智谱官方"
            case "deepseek": return "DeepSeek"
            case "anthropic": return "Anthropic"
            case "openai": return "OpenAI"
            default: return "官方·\(suffix)"
            }
        }
        // UUID 格式：查内置 UUID 映射表
        if let name = ProviderUUIDMap[provider] {
            return name
        }
        if provider.contains("-") && provider.count >= 8 {
            let short = String(provider.prefix(8))
            return "自定义·\(short)"
        }
        return provider
    }

    // 2. provider 为空（Claude 日志）→ 按 model 推断供应商
    return inferProviderFromModel(model)
}

/// Claude 日志无 provider 时，根据 model 名推断供应商
func inferProviderFromModel(_ model: String) -> String {
    // 词元之芯·Token工厂
    if model == "glm-52-w4a8-kv" || model == "glm-52-w4a8-kvp" {
        return "词元之芯·Token工厂"
    }
    // 通义千问
    if model.hasPrefix("qwen3") {
        return "通义千问"
    }
    // 豆包
    if model.hasPrefix("doubao-") {
        return "豆包"
    }
    // 火山引擎
    if model.hasPrefix("deepseek-v4-pro") {
        return "火山引擎"
    }
    // Minimax
    if model.hasPrefix("minimax-") {
        return "Minimax"
    }
    // 其他没匹配的：不显示后缀
    return ""
}

/// UUID provider 映射表（用户提供的供应商名）。
/// 这些 UUID 是 ZCode model_usage.provider_id 字段，区分同一 model 的不同供应商。
let ProviderUUIDMap: [String: String] = [
    "7aff2f39-217e-4f1c-82f6-b8e857a9be22": "浙算 MaaS",
    "e42dedab-efa4-4e63-9de5-8138073a2383": "词元之芯·Token工厂",
    "f2b1acc3-7c19-4a25-a6b5-f9783a0d91f9": "火山引擎",
]
