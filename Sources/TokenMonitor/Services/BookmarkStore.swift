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

    /// 迁移：旧版 bookmark 是用 `options: []`(不带 security scope) 存的,
    /// 新版改用 `.withSecurityScope`, 旧 bookmark resolve 时会抛 incompatible options
    /// 异常 (sqlite 实测日志给出的就是这种症状: startAccessing=false)。
    /// 启动时一次性清掉所有用旧 options 存的 bookmark, 让用户重新授权一次拿到 scope tag。
    @MainActor
    static func clearIncompatibleBookmarks() {
        let keysToCheck: [Key] = [.ccusageDB, .zcodeDB, .ccUsageExe, .claudeProjectsDir, .claudeSettings]
        var cleared = [String]()
        for k in keysToCheck {
            let raw = k.rawValue
            if UserDefaults.standard.data(forKey: raw) == nil { continue }
            // 用新 option 试 resolve, 失败/抛错 = 不兼容
            var stale = false
            do {
                let data = UserDefaults.standard.data(forKey: raw) ?? Data()
                _ = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                // resolve 成功就保留 (它是带 security scope 的)
            } catch {
                UserDefaults.standard.removeObject(forKey: raw)
                cleared.append(raw)
            }
        }
        if !cleared.isEmpty {
            DiagnosticLogger.log("clearIncompatibleBookmarks — 已清除不带 security scope 的旧 bookmark: \(cleared.joined(separator: ", "))")
        }
    }

    // MARK: - Save

    /// 把用户授权的 URL 存为 bookmark。
    /// 成功返回 true。
    ///
    /// 关键：sandbox=true 下必须用 `.withSecurityScope` option，否则重启后
    /// resolve 出来的 URL `startAccessingSecurityScopedResource()` 必然返回 false
    /// (sandbox 拒绝把 security scope 附给一个不带 scope tag 的 bookmark)。
    /// 这是用户日志里"startAccessing=false, 仍返回 URL 但读写会失败"的根因。
    @discardableResult
    func save(_ url: URL, for key: Key) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: key.rawValue)
            return true
        } catch {
            DiagnosticLogger.log("BookmarkStore.save(\(key.rawValue)) throws: \(error)")
            return false
        }
    }

    // MARK: - Resolve

    /// 还原 bookmark 为 URL，并调用 startAccessingSecurityScopedResource()。
    /// 返回的 URL 用完后**必须**调用 release()。
    ///
    /// 关键：sandbox=true 下 resolve 也必须用 `.withSecurityScope` option (跟 save 对称),
    /// 否则 resolve 出来的 URL 不带 security-scope tag, startAccessingSecurityScopedResource()
    /// 会返回 false。sandbox 下读外部文件唯一合法路径就是这条。
    /// resolve 在 startAccess 失败时返回 nil, 不再 fallback 返回 URL——否则上层会
    /// 拿到能存路径但不能读写的死 URL, 误导 UI 显示"路径有效但全 0 数据"假象。
    func resolve(_ key: Key) -> URL? {
        guard let data = defaults.data(forKey: key.rawValue) else {
            DiagnosticLogger.log("BookmarkStore.resolve(\(key.rawValue)) = nil — UserDefaults 里没存 bookmark data")
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // stale bookmark 需要用户重新授权（这里返回 nil 让 UI 提示）
            if isStale {
                defaults.removeObject(forKey: key.rawValue)
                DiagnosticLogger.log("BookmarkStore.resolve(\(key.rawValue)) = nil — bookmark 已 stale, 已清 UserDefaults")
                return nil
            }
            if url.startAccessingSecurityScopedResource() {
                DiagnosticLogger.log("BookmarkStore.resolve(\(key.rawValue)) OK startAccessing → \(url.path)")
                return url
            }
            // startAccess 失败：sandbox 没有 extension。返回 nil, 让上层走"请重新授权"路径。
            DiagnosticLogger.log("BookmarkStore.resolve(\(key.rawValue)) = nil — startAccessingSecurityScopedResource() 返回 false, sandbox 拒绝授权")
            return nil
        } catch {
            DiagnosticLogger.log("BookmarkStore.resolve(\(key.rawValue)) throws: \(error)")
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
