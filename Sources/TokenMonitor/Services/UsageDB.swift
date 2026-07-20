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

        // sandbox=true 下：优先用 security-scoped bookmark 授权的 URL
        // sandbox=false 下：bookmark 也没有，直接用路径
        let resolvedPath: String
        if let bookmarkURL = BookmarkStore.shared.resolve(.ccusageDB) {
            securityScopedURL = bookmarkURL
            resolvedPath = bookmarkURL.path
        } else {
            resolvedPath = path
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            securityScopedURL.map { BookmarkStore.shared.release($0) }
            return nil
        }

        // 两级降级：immutable=1 失败则 mode=ro，避免锁住正在写入的进程
        let candidates = [
            "file:\(resolvedPath)?immutable=1",
            "file:\(resolvedPath)?mode=ro",
        ]
        for url in candidates {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            if sqlite3_open_v2(url, &db, flags, nil) == SQLITE_OK {
                self.handle = db
                return
            }
            sqlite3_close(db)
        }
        securityScopedURL.map { BookmarkStore.shared.release($0) }
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
}
