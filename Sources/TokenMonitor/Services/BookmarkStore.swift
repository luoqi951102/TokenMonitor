import Foundation

// MARK: - BookmarkStore
//
// 管理 security-scoped bookmark：
//   - 用户通过 NSOpenPanel 授权 ccusage.db / db.sqlite / cc-usage 后
//   - 把授权转成 bookmark 存到 UserDefaults
//   - 下次启动时 resolve bookmark 还原 URL，调用 startAccessingSecurityScopedResource()
//   - sandbox=true 下读外部文件的唯一合法方式

final class BookmarkStore {
    static let shared = BookmarkStore()

    private let defaults = UserDefaults.standard

    enum Key: String {
        /// **`.claude` 目录授权**（不是 ccusage.db 文件！）
        /// sandbox 下 SQLite 要写 -wal/-shm 副文件，单文件 bookmark 不允许在同目录
        /// 创建副文件（SQLITE_CANTOPEN rc=14），所以这里授权整个 .claude 目录。
        /// 改 key 名以区分旧的 "bookmark_ccusage_db" 文件 bookmark，避免 sandbox
        /// 误用 stale 旧文件 bookmark。
        case ccusageDB = "bookmark_claude_dir"
        case zcodeDB = "bookmark_zcode_db"
        case ccUsageExe = "bookmark_cc_usage_exe"
        // Swift sync 私有化新增：扫描 JSONL 需要 projects 目录授权，读 settings.json 需要 settings 文件授权
        case claudeProjectsDir = "bookmark_claude_projects_dir"
        case claudeSettings = "bookmark_claude_settings"
    }

    private init() {}

    /// 迁移用：旧 key 名"bookmark_ccusage_db"曾经授权的是 ccusage.db 单文件，
    /// 现在切换到目录授权后必须清掉旧 bookmark 否则 sandbox 用 stale 文件
    /// bookmark 会破坏(用 Key.ccusageDB 已改名天然避开)。
    /// 启动时调一次清除旧 bookmark。
    static func clearStaleFileBookmarkIfAny() {
        let oldKey = "bookmark_ccusage_db"
        if UserDefaults.standard.data(forKey: oldKey) != nil {
            UserDefaults.standard.removeObject(forKey: oldKey)
        }
    }

    // MARK: - Save

    /// 把用户授权的 URL 存为 bookmark。
    /// 成功返回 true。
    @discardableResult
    func save(_ url: URL, for key: Key) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: key.rawValue)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Resolve

    /// 还原 bookmark 为 URL，并调用 startAccessingSecurityScopedResource()。
    /// 返回的 URL 用完后**必须**调用 release()。
    func resolve(_ key: Key) -> URL? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // stale bookmark 需要用户重新授权（这里返回 nil 让 UI 提示）
            if isStale {
                defaults.removeObject(forKey: key.rawValue)
                return nil
            }
            if url.startAccessingSecurityScopedResource() {
                return url
            }
            // 启动授权失败也返回 URL（用于路径展示），但读 db 会失败
            return url
        } catch {
            return nil
        }
    }

    /// 释放 security-scoped 资源（与 resolve 配对）
    func release(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Status

    func has(_ key: Key) -> Bool {
        defaults.data(forKey: key.rawValue) != nil
    }

    func pathString(_ key: Key) -> String? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return url.path
        }
        return nil
    }

    func clear(_ key: Key) {
        defaults.removeObject(forKey: key.rawValue)
    }

    func clearAll() {
        for key in [
            Key.ccusageDB, .zcodeDB, .ccUsageExe,
            .claudeProjectsDir, .claudeSettings,
        ] {
            clear(key)
        }
    }
}
