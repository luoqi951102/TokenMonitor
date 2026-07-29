import Foundation
import SQLite3

// MARK: - UsageDB
//
// 只读访问 ccusage.db（由 `cc-usage sync` 写入）。
// ccusage.db schema（参考 token-count ccusage/db.py）：
//   usage(
//     id, timestamp, local_date, local_hour, model,
//     input_tokens, cache_creation_input_tokens,
//     cache_read_input_tokens, output_tokens, total_context,
//     msg_count, session_id, cwd, project,
//     source_file, source, ext_id
//   )
//
// 注意：ccusage.db 不存 tool_call_count / reasoning_tokens。
// 这两个维度从 ZCode 原生库（~/.zcode/cli/db/db.sqlite 的 model_usage 表）补齐。
// 参见 ZCodeUsageDB。

final class UsageDB {
    private var handle: OpaquePointer?
    private var securityScopedURL: URL?
    let path: String

    init?(path: String) {
        self.path = path

        // Key.ccusageDB bookmark 授权的是 **`.claude` 目录**（详见 CCUsageDB.init?）。
        // sandbox=true 下必须走 bookmark, 不能 fallback 到 path (容器路径给假象成功)。
        // 跟 CCUsageDB.init 一致: 未授权 → 返回 nil (UI 显示"未连接", 上层明确路径)。
        guard let dirURL = BookmarkStore.shared.resolve(.ccusageDB) else {
            DiagnosticLogger.log("UsageDB init = nil — bookmark_claude_dir 未授权 / resolve 失败")
            return nil
        }
        securityScopedURL = dirURL
        let resolvedPath = UsageDBPath.ccusagePath(in: dirURL)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            BookmarkStore.shared.release(securityScopedURL!)
            securityScopedURL = nil
            DiagnosticLogger.log("UsageDB init = nil — \(resolvedPath) 文件不存在 (ccusage.db 还没建, 先手动同步一次让 CCUsageDB 建库)")
            return nil
        }

        // 关键：读 ccusage.db 必须读 -wal 副文件（Swift SyncRunner / Python cc-usage
        // 写的新数据都在 WAL 里，主库文件还是老快照）。
        //   - mode=ro   : 只读 + 读 WAL，能看到其他进程的写入 ✅
        //   - immutable=1: SQLite 假定文件永不变，**直接忽略 -wal**，只看主库快照 ❌
        // 之前 candidates 把 immutable=1 排在前面，导致 UI 永远显示老快照（10.24M 卡死
        // 而 DB 实际有 9097万 就是这个原因）。已彻底移除 immutable=1 候选。
        let candidates = [
            "file:\(resolvedPath)?mode=ro",
            "file:\(resolvedPath)",
        ]
        for url in candidates {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            if sqlite3_open_v2(url, &db, flags, nil) == SQLITE_OK {
                self.handle = db
                DiagnosticLogger.log("UsageDB init OK — path=\(resolvedPath)")
                return
            }
            sqlite3_close(db)
        }
        BookmarkStore.shared.release(securityScopedURL!)
        securityScopedURL = nil
        DiagnosticLogger.log("UsageDB init = nil — sqlite3_open_v2 全部候选失败")
        return nil
    }

    deinit {
        if let handle { sqlite3_close(handle) }
        if let url = securityScopedURL { BookmarkStore.shared.release(url) }
    }

    var isOpen: Bool { handle != nil }

    // MARK: - Query primitive

    /// 执行 SELECT，逐行回调。自动 finalize。
    func query(_ sql: String, params: [Any?] = [], _ rowHandler: (StatementRow) -> Void) {
        guard let handle else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        // 绑定参数（从 1 开始）
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let s as String:
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let n as Int:
                sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64:
                sqlite3_bind_int64(stmt, idx, n)
            case let d as Double:
                sqlite3_bind_double(stmt, idx, d)
            case nil:
                sqlite3_bind_null(stmt, idx)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            rowHandler(StatementRow(statement: stmt))
        }
    }

    /// 查询单值（聚合）
    func scalar(_ sql: String, params: [Any?] = []) -> Int {
        var result = 0
        query(sql, params: params) { row in
            result = row.int(at: 0)
        }
        return result
    }
}

// MARK: - Statement Row Helper

struct StatementRow {
    let statement: OpaquePointer?

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func string(at index: Int32) -> String {
        guard let cstr = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cstr)
    }

    func isNull(at index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}

// MARK: - DB Path Resolution

enum UsageDBPath {
    /// ccusage 默认 DB：~/.claude/ccusage.db
    static var ccusageDefault: String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/ccusage.db")
            .path
    }

    /// ZCode 原生 DB：~/.zcode/cli/db/db.sqlite
    static var zcodeDefault: String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".zcode/cli/db/db.sqlite")
            .path
    }

    /// 通过 .claude 目录 bookmark 解出 ccusage.db 的实际可写路径。
    ///
    /// 背景：sandbox 下 SQLite 要写 -wal / -shm 副文件，单文件 bookmark 不允许在同
    /// 目录创建副文件（SQLITE_CANTOPEN rc=14）。所以 ccusageDB bookmark 授权的是
    /// `~/.claude` 目录本身（不是 ccusage.db 文件），sandbox 才能读写目录内任意文件。
    /// 调用方需持有 bookmark URL（startAccessingSecurityScopedResource 已调）。
    ///
    /// - Parameter dirURL: 已 startAccessing 的 .claude 目录 URL
    /// - Returns: dirURL/ccusage.db 的路径
    static func ccusagePath(in dirURL: URL) -> String {
        dirURL.appendingPathComponent("ccusage.db").path
    }
}
