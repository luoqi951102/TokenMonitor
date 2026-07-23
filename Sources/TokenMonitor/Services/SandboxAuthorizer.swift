import AppKit

// MARK: - SandboxAuthorizer
//
// 集中管理 Swift sync 私有化所需的三个 NSOpenPanel 授权流程：
//   - claudeProjectsDir：~/.claude/projects 目录（扫 JSONL 必需，目录授权）
//   - zcodeDB：~/.zcode/cli/db/db.sqlite 文件（读 ZCode 原生库，单文件授权）
//   - claudeSettings：~/.claude/settings.json 文件（读当前 baseURL，单文件授权）
//
// sandbox=true 下，App 要读 sandbox 容器外的文件，必须先通过 NSOpenPanel 让用户
// 手动授权一次，转 security-scoped bookmark 持久化（BookmarkStore）。
// 之后启动时 resolve bookmark 还原 URL 即可访问，不必每次弹窗。
//
// 与 SettingsView.pickFile() 的区别：pickFile 是文件授权（canChooseFiles=true），
// 这里 projects 是目录授权（canChooseDirectories=true），所以独立一个集中器。

@MainActor
enum SandboxAuthorizer {

    enum AuthorizeResult {
        case granted
        case cancelled
        case failed
    }

    /// 弹 NSOpenPanel 让用户授权 ~/.claude/projects 目录。
    /// 成功后存到 BookmarkStore.Key.claudeProjectsDir。
    static func authorizeClaudeProjects() -> AuthorizeResult {
        var ok = false
        let panel = NSOpenPanel()
        panel.title = "授权访问 Claude 会话目录"
        panel.message = "Token Monitor 需要扫描 ~/.claude/projects 下的会话 JSONL 来统计 token 用量"
        panel.prompt = "授权扫描"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")

        let resp = panel.runModal()
        if resp == .OK, let url = panel.url {
            ok = BookmarkStore.shared.save(url, for: .claudeProjectsDir)
            return ok ? .granted : .failed
        }
        return .cancelled
    }

    /// 弹 NSOpenPanel 让用户授权 ~/.zcode/cli/db/db.sqlite 文件。
    static func authorizeZCodeDB() -> AuthorizeResult {
        let panel = NSOpenPanel()
        panel.title = "授权访问 ZCode 用量数据库"
        panel.message = "Token Monitor 需要读 ~/.zcode/cli/db/db.sqlite 来补齐工具调用数等维度"
        panel.prompt = "授权读取"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["sqlite", "sqlite3", "db"]
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zcode/cli/db")

        if panel.runModal() == .OK, let url = panel.url {
            let ok = BookmarkStore.shared.save(url, for: .zcodeDB)
            return ok ? .granted : .failed
        }
        return .cancelled
    }

    /// 弹 NSOpenPanel 让用户授权 ~/.claude/settings.json 文件。
    static func authorizeClaudeSettings() -> AuthorizeResult {
        let panel = NSOpenPanel()
        panel.title = "授权访问 Claude 配置文件"
        panel.message = "Token Monitor 需要读 settings.json 的 ANTHROPIC_BASE_URL 来给新行标供应商"
        panel.prompt = "授权读取"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["json"]
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")

        if panel.runModal() == .OK, let url = panel.url {
            let ok = BookmarkStore.shared.save(url, for: .claudeSettings)
            return ok ? .granted : .failed
        }
        return .cancelled
    }

    /// 三个授权是否都已就绪（用于 SyncRunner 判断能否跑真 sync）。
    static var allGranted: Bool {
        BookmarkStore.shared.has(.claudeProjectsDir)
            && BookmarkStore.shared.has(.zcodeDB)
            && BookmarkStore.shared.has(.ccusageDB)
    }
}
