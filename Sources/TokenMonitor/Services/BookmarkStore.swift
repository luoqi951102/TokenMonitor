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
        case ccusageDB = "bookmark_ccusage_db"
        case zcodeDB = "bookmark_zcode_db"
        case ccUsageExe = "bookmark_cc_usage_exe"
        // Swift sync 私有化新增：扫描 JSONL 需要 projects 目录授权，读 settings.json 需要 settings 文件授权
        case claudeProjectsDir = "bookmark_claude_projects_dir"
        case claudeSettings = "bookmark_claude_settings"
    }

    private init() {}

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
