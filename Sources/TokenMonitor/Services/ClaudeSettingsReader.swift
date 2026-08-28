import Foundation

// MARK: - ClaudeSettingsReader
//
// 读 ~/.claude/settings.json 里的 env.ANTHROPIC_BASE_URL。
// 移植自 token-count/ccusage/db.py 的 _read_claude_base_url()。
//
// 用途：Claude JSONL 不记 baseURL，所以只能 going-forward 给新行打标。
// CCM 切供应商时会把当前 baseURL 写到 settings.json 的 env.ANTHROPIC_BASE_URL。
// 读不出则返回空串（与 Python 一致）。
//
// sandbox 权限：优先用 Key.claudeSettings bookmark 解开的安全 URL；
// 没授权则回退尝试默认路径（sandbox 外或用户手动授权完整目录时可用）。

enum ClaudeSettingsReader {

    /// 读 settings.json 的 env.ANTHROPIC_BASE_URL，返回原文（如 "https://api.goodputai.cn"）。
    /// 读不出 / 不存在 / 坏 JSON 一律返回空串。
    static func readANTHRopicBaseURL() -> String {
        return readANTHRopicBaseURL(from: nil)
    }

    /// 显式指定 settings 路径（测试用）：传 nil 走 bookmark → 默认路径两级回退。
    static func readANTHRopicBaseURL(from explicitURL: URL?) -> String {
        let resolvedURL: URL?
        if let explicitURL {
            resolvedURL = explicitURL
        } else if let bookmarkURL = BookmarkStore.shared.resolve(.claudeSettings) {
            // bookmark 路径在持锁期间读
            defer { BookmarkStore.shared.release(bookmarkURL) }
            let value = readFromURL(bookmarkURL)
            return value
        } else {
            // 回退默认路径（sandbox 下多半读不到，但 sandbox=false 或已授权父目录时可读）
            resolvedURL = URL(fileURLWithPath: defaultSettingsPath())
        }

        guard let resolvedURL else { return "" }
        return readFromURL(resolvedURL)
    }

    /// 读指定 URL 的 settings.json，提取 env.ANTHROPIC_BASE_URL。
    private static func readFromURL(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        guard let env = dict["env"] as? [String: Any] else { return "" }
        let url = env["ANTHROPIC_BASE_URL"]
        if let s = url as? String { return s }
        return ""
    }

    /// 默认 settings 路径：~/.claude/settings.json
    private static func defaultSettingsPath() -> String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
            .path
    }
}
