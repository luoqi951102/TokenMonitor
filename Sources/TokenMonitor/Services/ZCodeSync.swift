import Foundation
import SQLite3

// MARK: - ZCodeSync
//
// 从 ~/.zcode/cli/db/db.sqlite 增量同步 model_usage 到 ccusage.db。
// 移植自 token-count/ccusage/db.py 的 sync_zcode()。
//
// 增量策略（与 Python 严格对齐）：
//   1. 水位线存 meta['zcode_last_completed_at']，首次=0
//   2. SELECT 13 列 FROM model_usage LEFT JOIN session
//      WHERE completed_at > watermark AND status='completed'
//      ORDER BY completed_at
//   3. 分桶用 started_at（用户实际开始用的时间），水位线用 completed_at（严禁混用）
//   4. ts_iso = 毫秒 epoch → UTC ISO "YYYY-MM-DDTHH:MM:SS.mmmZ"
//   5. INSERT OR IGNORE 17 列，source='zcode'，source_file=''，
//      靠 idx_usage_source_ext UNIQUE (source, ext_id) WHERE ext_id != '' 幂等
//   6. 水位线推进到这批的最大 completed_at
//
// ZCode 库打开方式：两级降级 immutable=1 → mode=ro（复用 ZCodeUsageDB 模式），
// 不碰 -wal/-shm，避免 ZCode 持锁时打开失败。
//
// 注意：ccusage.db 的 usage 表不存 tool_call_count / reasoning_tokens 列。
// 这两个维度由 ZCodeUsageDB 直接从 ZCode 原生库读，不经过 ccusage.db 中转。
// 所以 ZCodeSync 的 INSERT 不含 tool_call_count（与 Python 一致）。

struct ZCodeSyncStats {
    var new = 0
    var skipped = 0
    var errors = 0
    var watermarkBefore: Int64 = 0
    var watermarkAfter: Int64 = 0
}

enum ZCodeSync {

    // MARK: - 时区（Asia/Shanghai，与 ClaudeSync / ZCodeUsageDB 同口径）

    private static let shanghai: TimeZone =
        TimeZone(identifier: "Asia/Shanghai") ?? .current

    /// 毫秒 epoch → (上海日期 "YYYY-MM-DD", 小时 0-23)。
    /// 移植自 Python _local_parts_epoch()。
    static func localPartsEpoch(ms: Int64) -> (date: String, hour: Int) {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        let c = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return (
            String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
            c.hour ?? 0
        )
    }

    /// 毫秒 epoch → UTC ISO "YYYY-MM-DDTHH:MM:SS.mmmZ"（与 Claude jsonl timestamp 同格式）。
    /// 移植自 Python _epoch_ms_to_iso()：用 strftime 出到秒，再补毫秒补零 3 位。
    /// Python 用浮点 ms/1000 转 timestamp 可能丢毫秒精度，所以它用 `ms % 1000` 单独补。
    /// Swift 这里直接用 Int 取整 + 模运算，结果等价。
    static func epochMsToISO(ms: Int64) -> String {
        let secs = Int(ms / 1000)
        let millis = Int(ms % 1000)
        let date = Date(timeIntervalSince1970: TimeInterval(secs))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return "\(f.string(from: date)).\(String(format: "%03d", millis))Z"
    }

    // MARK: - sync

    /// 增量同步 ZCode model_usage → ccusage.db。
    /// db：已打开的可写 ccusage.db 句柄。
    /// zcodeDB URL：ZCode 原生库路径，必须已是 security-scoped 持锁状态（SyncRunner 管）。
    /// 不存在或打不开返回 stats（new=0，上层可跳过）。
    static func sync(
        db: CCUsageDB,
        zcodeDB url: URL
    ) -> ZCodeSyncStats {
        var stats = ZCodeSyncStats()

        guard FileManager.default.fileExists(atPath: url.path) else {
            return stats
        }

        // 1. 打开 ZCode 库（两级降级，复用 ZCodeUsageDB 模式）
        //    用 SQLITE_OPEN_READONLY | SQLITE_OPEN_URI，不碰 -wal/-shm
        var srcHandle: OpaquePointer?
        let candidates = [
            "file:\(url.path)?immutable=1",
            "file:\(url.path)?mode=ro",
        ]
        var opened = false
        for uri in candidates {
            var h: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            if sqlite3_open_v2(uri, &h, flags, nil) == SQLITE_OK {
                // 探测：能 SELECT COUNT(*) 才算真打开
                var probe: OpaquePointer?
                if sqlite3_prepare_v2(h, "SELECT COUNT(*) FROM model_usage", -1, &probe, nil) == SQLITE_OK {
                    if sqlite3_step(probe) == SQLITE_ROW {
                        srcHandle = h
                        opened = true
                        sqlite3_finalize(probe)
                        break
                    }
                    sqlite3_finalize(probe)
                }
                sqlite3_close(h)
            }
        }
        guard opened, let srcHandle else {
            return stats
        }
        defer { sqlite3_close(srcHandle) }

        // 2. 读水位线（首次=0）
        let wmStr = db.getMeta("zcode_last_completed_at") ?? "0"
        let watermark = Int64(wmStr) ?? 0
        stats.watermarkBefore = watermark

        // 3. SELECT 13 列
        let selectSQL = """
        SELECT m.id, m.started_at, m.completed_at, m.model_id,
               m.input_tokens, m.cache_creation_input_tokens,
               m.cache_read_input_tokens, m.output_tokens,
               m.computed_total_tokens, m.tool_call_count,
               m.session_id, s.directory, m.provider_id
        FROM model_usage m
        LEFT JOIN session s ON m.session_id = s.id
        WHERE m.completed_at > ? AND m.status = 'completed'
        ORDER BY m.completed_at
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(srcHandle, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
            return stats
        }
        defer { sqlite3_finalize(selectStmt) }
        sqlite3_bind_int64(selectStmt, 1, watermark)

        // 4. 读全部行到内存（与 Python fetchall 等价；ZCode 增量通常几百到几千行）
        struct ZRow {
            let extID: String
            let startedAt: Int64
            let completedAt: Int64
            let modelID: String
            let inp, cw, cr, outp, total: Int
            let sessionID: String
            let directory: String
            let providerID: String
        }
        var rows: [ZRow] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            func colStr(_ idx: Int32) -> String {
                if let c = sqlite3_column_text(selectStmt, idx) {
                    return String(cString: c)
                }
                return ""
            }
            func colInt(_ idx: Int32) -> Int {
                Int(sqlite3_column_int64(selectStmt, idx))
            }
            func colInt64(_ idx: Int32) -> Int64 {
                sqlite3_column_int64(selectStmt, idx)
            }
            // 跳过 started_at 为空的行（无法分桶）；Python 是 except ValueError 跳过
            let startedMs = colInt64(1)
            if startedMs <= 0 {
                stats.errors += 1
                continue
            }
            rows.append(ZRow(
                extID: colStr(0),
                startedAt: startedMs,
                completedAt: colInt64(2),
                modelID: colStr(3),
                inp: colInt(4),
                cw: colInt(5),
                cr: colInt(6),
                outp: colInt(7),
                total: colInt(8),
                sessionID: colStr(10),
                directory: colStr(11),
                providerID: colStr(12)
            ))
        }

        guard !rows.isEmpty else {
            stats.watermarkAfter = watermark
            return stats
        }

        // 5. 批量 INSERT OR IGNORE（靠 idx_usage_source_ext_UNIQUE 幂等）。
        //    统计法与 Python 完全一致：transaction 内先取 before count，批量 INSERT 后取 after count，
        //    new = after - before，skipped = rows.count - new。水位线推进到本批最大 completed_at。
        let insertSQL = """
        INSERT OR IGNORE INTO usage
        (timestamp, local_date, local_hour, model,
         input_tokens, cache_creation_input_tokens,
         cache_read_input_tokens, output_tokens, total_context,
         msg_count, session_id, cwd, project, source_file, source, ext_id, provider)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'','zcode',?,?)
        """
        let insertStmt = db.prepare(insertSQL)
        guard let insertStmt else {
            stats.errors += rows.count
            return stats
        }

        var newWatermark = watermark
        var insertedThisBatch = 0

        db.transaction {
            // before count：在 INSERT 前取（事务内可见一致快照的关键）
            let before = db.scalar("SELECT COUNT(*) FROM usage WHERE source='zcode'")

            for row in rows {
                let parts = localPartsEpoch(ms: row.startedAt)
                let tsISO = epochMsToISO(ms: row.startedAt)
                let params: [Any?] = [
                    tsISO,         // 1 timestamp
                    parts.date,    // 2 local_date
                    parts.hour,    // 3 local_hour
                    row.modelID,   // 4 model
                    row.inp,       // 5 input_tokens
                    row.cw,        // 6 cache_creation_input_tokens
                    row.cr,        // 7 cache_read_input_tokens
                    row.outp,      // 8 output_tokens
                    row.total,     // 9 total_context
                    1,             // 10 msg_count
                    row.sessionID, // 11 session_id
                    row.directory, // 12 cwd
                    row.directory, // 13 project
                    row.extID,     // 14 ext_id
                    row.providerID,// 15 provider
                ]
                db.stepOnce(insertStmt, params: params)

                if row.completedAt > newWatermark {
                    newWatermark = row.completedAt
                }
            }

            let after = db.scalar("SELECT COUNT(*) FROM usage WHERE source='zcode'")
            insertedThisBatch = after - before
        }

        stats.new = insertedThisBatch
        stats.skipped = rows.count - insertedThisBatch

        // 6. 推进水位线
        if newWatermark > watermark {
            db.setMeta("zcode_last_completed_at", String(newWatermark))
        }
        stats.watermarkAfter = newWatermark

        return stats
    }
}
