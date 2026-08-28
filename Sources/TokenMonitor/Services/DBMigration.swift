import Foundation
import SQLite3

// MARK: - DBMigration
//
// ccusage.db 的建表 + 迁移逻辑，与 Python token-count/ccusage/db.py SCHEMA 严格对齐。
//
// usage 表 17 列（含自增 id）；files 表（path/mtime/size/records）；meta 表（key/value）。
// 迁移：旧 Python 库可能缺 source/ext_id/provider 列，幂等 ALTER 补齐。
//
// Swift 端只在这一个文件里持有权威 schema 常量，CCUsageDB / Backfiller / ZCodeSync
// 等写入方都引用这里，避免多处硬编码 SCHEMA 导致漂移。

enum DBMigration {

    /// 建表 + 基础索引（幂等）。与 db.py SCHEMA 完全一致。
    static let createSchemaSQL = """
    CREATE TABLE IF NOT EXISTS usage (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        local_date TEXT NOT NULL,
        local_hour INTEGER NOT NULL,
        model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL DEFAULT 0,
        cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
        cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        total_context INTEGER NOT NULL DEFAULT 0,
        msg_count INTEGER NOT NULL DEFAULT 1,
        session_id TEXT,
        cwd TEXT,
        project TEXT,
        source_file TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'claude',
        ext_id TEXT NOT NULL DEFAULT '',
        provider TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_usage_date ON usage(local_date);
    CREATE INDEX IF NOT EXISTS idx_usage_date_model ON usage(local_date, model);
    CREATE INDEX IF NOT EXISTS idx_usage_model ON usage(model);
    CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage(timestamp);

    CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY,
        mtime REAL NOT NULL,
        size INTEGER NOT NULL,
        records INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """

    /// source/ext_id/provider 相关的幂等索引（新旧库都得建）。
    static let sourceIndexSQL = """
    CREATE INDEX IF NOT EXISTS idx_usage_source ON usage(source);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_source_ext ON usage(source, ext_id) WHERE ext_id != '';
    CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage(provider);
    CREATE INDEX IF NOT EXISTS idx_usage_model_provider ON usage(model, provider);
    """

    /// 启动时幂等建表 + 迁移。在已打开的 handle 上执行。
    /// 流程严格对齐 Python connect()：建表 → 查缺列 → ALTER → 建 source 索引 → PRAGMA。
    static func idempotentMigrate(on handle: OpaquePointer) {
        // 1. 建表 + 基础索引（exec 里多条语句一次性执行）
        exec(on: handle, createSchemaSQL)

        // 2. 旧库迁移：补 source / ext_id / provider 三列（幂等，已存在则跳过）
        //    PRAGMA table_info(usage) 各行 cid/name/type/notnull/dflt_value/pk
        var existingCols: Set<String> = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "PRAGMA table_info(usage)", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 1) {
                    existingCols.insert(String(cString: cstr))
                }
            }
        }
        sqlite3_finalize(stmt)

        if !existingCols.contains("source") {
            exec(on: handle, "ALTER TABLE usage ADD COLUMN source TEXT NOT NULL DEFAULT 'claude'")
        }
        if !existingCols.contains("ext_id") {
            exec(on: handle, "ALTER TABLE usage ADD COLUMN ext_id TEXT NOT NULL DEFAULT ''")
        }
        if !existingCols.contains("provider") {
            exec(on: handle, "ALTER TABLE usage ADD COLUMN provider TEXT NOT NULL DEFAULT ''")
        }

        // 3. source 相关幂等索引（列已就位，新旧库都建）
        exec(on: handle, sourceIndexSQL)

        // 4. PRAGMA（单条语句，不能放进 exec 多语句里和建表混用 WAL 切换）
        exec(on: handle, "PRAGMA journal_mode=WAL")
        exec(on: handle, "PRAGMA synchronous=NORMAL")
    }

    /// 在已打开的 handle 上执行可能包含多条语句的 SQL（CREATE ... ; CREATE ... ;）。
    /// 用 sqlite3_exec 而非 prepare/step，因为 exec 才能一次性跑多条 DDL。
    /// 任何子语句失败都直接忽略（迁移是幂等的，失败多半是"已存在"）。
    private static func exec(on handle: OpaquePointer, _ sql: String) {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }
}
