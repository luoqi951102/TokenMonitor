import Foundation
import SQLite3

// MARK: - CCUsageDB
//
// 可写访问 ccusage.db —— Swift 端自带的 sync / backfill / dedupe 写入通道。
//
// 与只读 `UsageDB`（读 KPI 用）平级，但句柄用 `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE`，
// 启动时跑 `DBMigration.idempotentMigrate(on:)` 幂等建表 + 迁移旧库列，与 Python
// token-count/ccusage/db.py 的 connect() 等价。
//
// 注意：sandbox=true 下要写 ~/.claude/ccusage.db 必须有 security-scoped bookmark（Key.ccusageDB）。
// 没有授权则 init 返回 nil —— 上层应当引导用户授权（SandboxAuthorizer）再重 init。
//
// 写接口约定（ClaudeSync / ZCodeSync / Backfiller 都遵守）：
//   - 单次 sync 全程复用同一个 CCUsageDB 实例（不开多连接，避免 WAL 写锁竞争）
//   - 批量写用 transaction { } 包裹，减少 fsync 次数
//   - 参数绑定走 bindParam(_:at:) 统一处理 String/Int/Double/nil

final class CCUsageDB {
    private var handle: OpaquePointer?
    private var securityScopedURL: URL?
    let path: String

    var isOpen: Bool { handle != nil }

    init?(path: String) {
        self.path = path

        // sandbox=true 下：必须先用 security-scoped bookmark 解开路径
        // sandbox=false 下：bookmark 也没有，直接用传入路径
        let resolvedPath: String
        if let bookmarkURL = BookmarkStore.shared.resolve(.ccusageDB) {
            securityScopedURL = bookmarkURL
            resolvedPath = bookmarkURL.path
        } else {
            resolvedPath = path
        }

        // 先确保父目录存在（sandbox 下通常 ~/.claude 已在，但不保证）
        let parent = (resolvedPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )

        // 用 URI 形式打开，跟只读端一致（支持 query string）
        // READWRITE | CREATE：库不存在则新建，存在则可读写
        let uri = "file:\(resolvedPath)"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            securityScopedURL.map { BookmarkStore.shared.release($0) }
            return nil
        }
        self.handle = db

        // 启动即建表 + 迁移旧库列 + PRAGMA WAL（全程幂等，已存在无副作用）
        if let handle {
            DBMigration.idempotentMigrate(on: handle)
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
        if let url = securityScopedURL { BookmarkStore.shared.release(url) }
    }

    // MARK: - Write primitives

    /// 执行可能包含多条语句的 DDL/DML（CREATE/PRAGMA/批量 DELETE 等）。
    /// 参数无法绑定，仅用于无参 SQL。失败忽略（迁移幂等）。
    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let handle else { return false }
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    /// 执行单条参数化 DML（INSERT/UPDATE/DELETE）。
    /// 返回受影响行数（sqlite3_changes）。
    @discardableResult
    func execute(_ sql: String, params: [Any?] = []) -> Int {
        guard let handle else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            bindParam(param, at: Int32(i + 1), to: stmt)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    /// 预编译一条语句并返回它，供批量和查询复用。
    /// 调用方负责 finalize。
    func prepare(_ sql: String) -> OpaquePointer? {
        guard let handle else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        return stmt
    }

    /// 把一个已准备好的语句执行一次（bind → step → reset → clear_bindings）。
    /// 返回是否成功（DONE 或 ROW；批量 INSERT 用 DONE 判断）。
    @discardableResult
    func stepOnce(_ stmt: OpaquePointer?, params: [Any?] = []) -> Bool {
        guard let stmt else { return false }
        for (i, param) in params.enumerated() {
            bindParam(param, at: Int32(i + 1), to: stmt)
        }
        let rc = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    /// 事务包装：BEGIN … COMMIT，异常时 ROLLBACK。
    /// 与 Python sqlite3 的 with conn 惯用法等价（Python 默认每条语句即提交，速度差；
    //          Swift 端显式包事务批量提交）。
    func transaction<T>(_ body: () throws -> T) rethrows -> T {
        exec("BEGIN")
        do {
            let result = try body()
            exec("COMMIT")
            return result
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Query (复用只读端的 StatementRow 风格，但这里自己声明一个轻量版避免循环依赖)

    /// 执行 SELECT，逐行回调。用于 backfill/reconcile 扫历史行。
    func query(_ sql: String, params: [Any?] = [], _ rowHandler: (StatementRow) -> Void) {
        guard let handle else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            bindParam(param, at: Int32(i + 1), to: stmt)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            rowHandler(StatementRow(statement: stmt))
        }
    }

    /// 查询单个聚合值（Int）。
    func scalar(_ sql: String, params: [Any?] = []) -> Int {
        var result = 0
        query(sql, params: params) { row in
            result = row.int(at: 0)
        }
        return result
    }

    // MARK: - meta 表

    /// 读 meta[key] 值，不存在返回 nil。
    func getMeta(_ key: String) -> String? {
        var value: String?
        query("SELECT value FROM meta WHERE key=?", params: [key]) { row in
            value = row.string(at: 0)
        }
        return value
    }

    /// 写 meta[key] = value（UPSERT）。
    func setMeta(_ key: String, _ value: String) {
        execute(
            "INSERT INTO meta(key,value) VALUES(?,?) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params: [key, value]
        )
    }

    // MARK: - Param binding

    /// 绑定单个参数。与 UsageDB.query 的 switch 列表保持一致。
    /// SQLITE_TRANSIENT 让 sqlite 拷贝字符串，避免释放后悬垂。
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    private func bindParam(_ param: Any?, at idx: Int32, to stmt: OpaquePointer?) {
        guard let stmt else { return }
        switch param {
        case let s as String:
            sqlite3_bind_text(stmt, idx, s, -1, Self.SQLITE_TRANSIENT)
        case let n as Int:
            sqlite3_bind_int64(stmt, idx, Int64(n))
        case let n as Int64:
            sqlite3_bind_int64(stmt, idx, n)
        case let n as Int32:
            sqlite3_bind_int(stmt, idx, n)
        case let d as Double:
            sqlite3_bind_double(stmt, idx, d)
        case let b as Bool:
            sqlite3_bind_int(stmt, idx, b ? 1 : 0)
        case nil:
            sqlite3_bind_null(stmt, idx)
        default:
            // 兜底：转字符串绑，避免类型未覆盖时静默插 null
            let s = String(describing: param)
            sqlite3_bind_text(stmt, idx, s, -1, Self.SQLITE_TRANSIENT)
        }
    }
}
