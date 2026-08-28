import Foundation

// MARK: - ProviderClassifier
//
// 根据 Claude JSONL 的 message.id 格式推断供应商 baseURL。
// 移植自 token-count/ccusage/db.py 的 _classify_provider_from_msgid() + _MSGID_PATTERNS。
//
// msg.id 是 Claude Code 转发请求时各供应商响应里返回的 request_id 原文格式，
// 比任何其他 Claude JSONL 字段都更可靠地区分供应商。
//
// 已知格式（来自实测）：
//   ^021\d+                          火山方舟 request_id（覆盖 deepseek-v4-flash/pro/doubao/minimax-m3）
//   ^msg_01[A-Za-z0-9]{4,}           Anthropic 官方格式（用户确认经浙算 MaaS 代理，覆盖 claude-opus-4-8）
//   ^msg_[0-9a-f]{32}$               goodputai 量化部署格式（无连字符 32 位 hex，覆盖 glm-52-w4a8-kv/kvp）
//   ^msg_\d{14,}                     goodputai 代理格式（msg_ + 14 位以上时间戳，覆盖 glm-5.2 大部分）
//   ^msg_<标准 UUID>$                按 model 分流：qwen* → 通义 / glm* → 浙算 MaaS / 其他 → 空
//   ^chatcmpl-                       OpenAI 标准格式（OpenAI 兼容代理，仅 qwen3 少量不确定）
//
// 返回 baseURL 原文（写入 ccusage.db usage.provider 列），无匹配返回空串。

enum ProviderClassifier {

    /// msgid 指纹 → (正则, baseURL)。用 NSRegularExpression 预编译。
    /// 注意：Python 用 re.match（锚定 ^），NSRegularExpression 加 ^ 锚点等价。
    private static let patterns: [(regex: NSRegularExpression, url: String)] = {
        // 注意：Swift 字符串字面量需要双反斜杠转义正则元字符（\\d / \\w）
        let raw: [(String, String)] = [
            ("^021\\d+", "https://ark.cn-beijing.volces.com/api/coding"),
            ("^msg_01[A-Za-z0-9]{4,}", "https://ai.zj-computility.com/maas"),
            ("^msg_[0-9a-f]{32}$", "https://api.goodputai.cn"),
            ("^msg_\\d{14,}", "https://api.goodputai.cn"),
        ]
        return raw.compactMap { pat, url in
            guard let re = try? NSRegularExpression(pattern: pat, options: []) else {
                return nil
            }
            return (re, url)
        }
    }()

    /// 标准 UUID 格式的正则（msg_ 前缀 + UUID），命中后按 model 分流。
    private static let uuidRegex: NSRegularExpression = {
        // msg_xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        let pat = "^msg_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        return try! NSRegularExpression(pattern: pat, options: [])
    }()

    /// OpenAI chatcmpl- 前缀（少数 qwen3 不确定，Python 也未给明确 url，这里返回空与 Python 一致）
    /// Python _MSGID_PATTERNS 列表里没列 chatcmpl-，只在注释提到。保持与 Python 行为一致：不命中。

    /// 根据 message.id 格式推断 provider baseURL。
    /// - Parameters:
    ///   - msgID: Claude JSONL message.id 原文
    ///   - model: 同一行的 model 名（UUID 格式按 model 分流用）
    /// - Returns: baseURL 原文，无匹配返回 ""
    static func classifyProviderFromMsgID(_ msgID: String, model: String) -> String {
        if msgID.isEmpty { return "" }

        let range = NSRange(msgID.startIndex..<msgID.endIndex, in: msgID)

        // 1. 四条显式模式
        for (regex, url) in patterns {
            if regex.firstMatch(in: msgID, options: [], range: range) != nil {
                return url
            }
        }

        // 2. 标准 UUID 格式 → 按 model 分流
        if uuidRegex.firstMatch(in: msgID, options: [], range: range) != nil {
            if model.hasPrefix("qwen") {
                return "https://coding.dashscope.aliyuncs.com/apps/anthropic"
            }
            if model.hasPrefix("glm") {
                return "https://ai.zj-computility.com/maas"
            }
            return ""
        }

        return ""
    }
}
