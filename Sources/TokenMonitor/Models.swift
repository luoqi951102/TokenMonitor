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

    /// 极简短标签（用于浮窗等窄空间场景）。CC = Claude Code，ZC = ZCode。
    var shortLabel: String {
        switch self {
        case .claude: return "CC"
        case .zcode:  return "ZC"
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
/// 三种 provider 字段格式（来自 cc-usage sync）：
///   1. baseURL 原文（Claude going-forward）：https://api.goodputai.cn  → 走 BaseURLProviderMap 内置表 / 用户别名
///   2. "builtin:xxx"（ZCode 内置供应商）：      builtin:bigmodel-coding-plan → 智谱官方
///   3. UUID（ZCode 自定义供应商）：            7aff2f39-... → 走 ProviderUUIDMap
///   4. 空（Claude 历史无 baseURL 记录）：       → 走 inferProviderFromModel(model)
///
/// 内置 UUID 映射（用户提供的）：
///   7aff2f39-217e-4f1c-82f6-b8e857a9be22 → 浙算 MaaS
///   e42dedab-efa4-4e63-9de5-8138073a2383 → 词元之芯·Token工厂
///   f2b1acc3-7c19-4a25-a6b5-f9783a0d91f9 → 火山引擎
///
/// 内置 baseURL 映射（从 CCM ccm.sh 源码挖出，11 条标准供应商 + 1 条用户补充）：
///   https://api.z.ai/api/anthropic                            → 智谱官方·国际
///   https://open.bigmodel.cn/api/anthropic                    → 智谱官方·国内
///   https://api.deepseek.com/anthropic                        → DeepSeek
///   https://api.moonshot.ai/anthropic                         → 月之暗面·国际
///   https://api.moonshot.cn/anthropic                         → 月之暗面·国内
///   https://coding-intl.dashscope.aliyuncs.com/apps/anthropic → 通义千问·国际
///   https://coding.dashscope.aliyuncs.com/apps/anthropic      → 通义千问·国内
///   https://api.minimax.io/anthropic                          → Minimax·国际
///   https://api.minimaxi.com/anthropic                        → Minimax·国内
///   https://ark.cn-beijing.volces.com/api/coding              → 火山引擎
///   https://api.stepfun.ai/v1/anthropic                       → StepFun
///   https://api.anthropic.com/                                → Anthropic 官方
///   https://api.goodputai.cn                                  → 词元之芯·Token工厂 (用户补充)
///
/// model 维度推断（仅 Claude 历史 provider 为空时）：
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
    // 同时支持 base URL / UUID / builtin:xxx 三种 key
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
        // baseURL 带 http(s):// 前缀 → 走 baseURL 映射表
        if provider.hasPrefix("http://") || provider.hasPrefix("https://") {
            if let name = BaseURLProviderMap[provider] {
                return name
            }
            // 未知 baseURL（第三方代理）：提取 host 末段做后缀
            // https://api.goodputai.cn → goodputai.cn
            if let host = URL(string: provider)?.host {
                return "代理·\(host)"
            }
            return "代理·未知"
        }
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

    // 2. provider 为空（Claude 历史）→ 按 model 推断供应商
    return inferProviderFromModel(model)
}

/// Claude 日志无 provider 时，根据 model 名推断供应商
func inferProviderFromModel(_ model: String) -> String {
    // 词元之芯·Token工厂
    if model == "glm-52-w4a8-kv" || model == "glm-52-w4a8-kvp" {
        return "词元之芯·Token工厂"
    }
    // 浙算 MaaS（用户确认的历史归属）
    // - glm-5.1: msg.id 100% 走 msg_<uuid> 格式，与 May25 settings.json 备份里 ai.zj-computility.com/maas 印证
    // - claude-opus-4-8: msg.id 走 msg_01XXX 格式（看着像 Anthropic 官方），由用户确认经浙算 MaaS 代理
    if model == "glm-5.1" || model == "claude-opus-4-8" {
        return "浙算 MaaS"
    }
    // 火山引擎（基于 msg.id 021_ 火山方舟指纹 + 用户确认）
    // - minimax-m3: 021_ 100%，实际是火山引擎方舟挂的 minimax 模型
    // - deepseek-v4-pro: 火山方舟部署的 DeepSeek
    if model == "minimax-m3" || model.hasPrefix("deepseek-v4-pro") {
        return "火山引擎"
    }
    // 豆包
    if model.hasPrefix("doubao-") {
        return "豆包"
    }
    // 通义千问
    if model.hasPrefix("qwen3") {
        return "通义千问"
    }
    // Minimax 通用兜底（如未来出现 minimax-* 但不走方舟代理时）
    if model.hasPrefix("minimax-") {
        return "Minimax"
    }
    // 其他没匹配的（如 glm-5.2、deepseek-v4-flash 等）：
    // Claude JSONL 不记 baseURL，事后无法回溯真实供应商，留空待用户补充。
    // 如果有 baseURL 标签（going-forward sync 写入），优先于本函数返回值。
    return ""
}

/// UUID provider 映射表（用户提供的供应商名）。
/// 这些 UUID 是 ZCode model_usage.provider_id 字段，区分同一 model 的不同供应商。
let ProviderUUIDMap: [String: String] = [
    "7aff2f39-217e-4f1c-82f6-b8e857a9be22": "浙算 MaaS",
    "e42dedab-efa4-4e63-9de5-8138073a2383": "词元之芯·Token工厂",
    "f2b1acc3-7c19-4a25-a6b5-f9783a0d91f9": "火山引擎",
]

/// baseURL → 友好名映射表。
/// Claude 走 cc-usage sync 时读 ~/.claude/settings.json 的 ANTHROPIC_BASE_URL 写入 provider 列，
/// 该字段原文即为 baseURL。Swift 端用它把 URL 翻译成可读供应商名。
/// 标准映射来自 CCM ccm.sh（11 条），goodputai.cn / ai.zj-computility.com 为用户补充（第三方代理）。
/// 不在表内的 baseURL 会退化为「代理·<host>」。
let BaseURLProviderMap: [String: String] = [
    "https://api.z.ai/api/anthropic": "智谱官方·国际",
    "https://open.bigmodel.cn/api/anthropic": "智谱官方·国内",
    "https://api.deepseek.com/anthropic": "DeepSeek",
    "https://api.moonshot.ai/anthropic": "月之暗面·国际",
    "https://api.moonshot.cn/anthropic": "月之暗面·国内",
    "https://coding-intl.dashscope.aliyuncs.com/apps/anthropic": "通义千问·国际",
    "https://coding.dashscope.aliyuncs.com/apps/anthropic": "通义千问·国内",
    "https://api.minimax.io/anthropic": "Minimax·国际",
    "https://api.minimaxi.com/anthropic": "Minimax·国内",
    "https://ark.cn-beijing.volces.com/api/coding": "火山引擎",
    "https://api.stepfun.ai/v1/anthropic": "StepFun",
    "https://api.anthropic.com/": "Anthropic 官方",
    "https://api.goodputai.cn": "词元之芯·Token工厂",
    "https://ai.zj-computility.com/maas": "浙算 MaaS",
]
