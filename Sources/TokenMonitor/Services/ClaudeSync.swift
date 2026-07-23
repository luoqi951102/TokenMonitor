import Foundation

// MARK: - ClaudeSync
//
// 扫描 ~/.claude/projects/**/*.jsonl，增量同步 usage 行到 ccusage.db。
// 移植自 token-count/ccusage/db.py 的 sync()。
//
// 增量策略（与 Python 严格对齐）：
//   1. files 表记录已解析文件的 (path, mtime, size)；未变化则跳过
//   2. 文件变了：先 SELECT (timestamp, provider) 快照 → DELETE 旧行 → 重新解析 INSERT
//      快照的作用：会话文件被 append 后整盘改写，若不保护会把"已标注 provider"
//      的旧行全部刷成当前 baseURL（脏数据）。所以只在 snapshot 有非空 provider
//      时沿用旧值，否则给新行打当前 baseURL。
//   3. 消失文件清理：known - seen → DELETE usage + files
//   4. 写 meta.last_sync = now
//
// 时区一致性：分桶固定 Asia/Shanghai（~ZCodeUsageDB.shanghai / Aggregator.shanghai 同口径）。
// ISO timestamp 原样保留（INSERT 时直接存字符串，不转 Date 再格式化）——provider 快照
// 按 timestamp 精确匹配的关键。

struct ClaudeSyncStats {
    var scanned = 0
    var newFiles = 0
    var updated = 0
    var skipped = 0
    var records = 0
    var errors = 0
}

enum ClaudeSync {

    // MARK: - 时区（Asia/Shanghai，与 Aggregator/ZCodeUsageDB 同口径）

    private static let shanghai: TimeZone =
        TimeZone(identifier: "Asia/Shanghai") ?? .current

    /// UTC ISO 字符串 → (上海日期 "YYYY-MM-DD", 小时 0-23)。
    /// 移植自 Python _local_parts()：fromisoformat(把 Z 换成 +00:00) → astimezone(SH)。
    /// 解析失败返回 nil（上层跳过该行并计数 errors）。
    static func localParts(fromISO ts: String) -> (date: String, hour: Int)? {
        // ISO8601DateFormatter 支持 "2026-05-29T09:05:31.140Z"
        // 用 formatOptions 包含 withInternetDateTime + withFractionalSeconds
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        formatter.timeZone = TimeZone(identifier: "UTC")

        // 兼容无毫秒的形式：先试带 fraction，失败再试纯 internetDateTime
        guard let utcDate = formatter.date(from: ts) else {
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            basic.timeZone = TimeZone(identifier: "UTC")
            guard let d = basic.date(from: ts) else { return nil }
            return partsFrom(date: d)
        }
        return partsFrom(date: utcDate)
    }

    private static func partsFrom(date: Date) -> (date: String, hour: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        let y = comps.year ?? 0, m = comps.month ?? 0, d = comps.day ?? 0
        let h = comps.hour ?? 0
        return (String(format: "%04d-%02d-%02d", y, m, d), h)
    }

    // MARK: - sync

    /// 增量同步。projectsDirURL 必须已经是 security-scoped 持锁状态（由 SyncRunner 管）。
    /// db 是已经打开的可写 CCUsageDB（同一进程复用一个连接）。
    /// force=true 时忽略 files 水位，全盘重扫（用于对账测试或修复）。
    static func sync(
        db: CCUsageDB,
        projectsDirURL: URL,
        force: Bool = false
    ) -> ClaudeSyncStats {
        var stats = ClaudeSyncStats()

        // 1. 读 files 水位表到内存 dict，key=path, value=(mtime, size)
        var knownFiles: [String: (mtime: Double, size: Int)] = [:]
        if !force {
            db.query("SELECT path, mtime, size FROM files") { row in
                knownFiles[row.string(at: 0)] = (row.double(at: 1), row.int(at: 2))
            }
        }

        var seenPaths: Set<String> = []

        // 2. 拿当前 baseURL，用于给新行打标
        let currentBaseURL = ClaudeSettingsReader.readANTHRopicBaseURL()

        // 3. 遍历所有 jsonl 文件
        //    securityScoped: projectsDirURL 已是持锁 URL，这里读子目录都能命中
        let files = ClaudeJSONLParser.iterJSONLFiles(
            projectsDir: projectsDirURL, securityScoped: true
        )

        // 预编译 INSERT 语句（与 Python 兼容：只显式写 14 列 + provider，共 15 个占位符；
        // source_file/source/ext_id 中：source_file 显式给，source/ext_id 走默认 'claude'/'')
        // 但 Python DB 的 source 默认值是 'claude'，我们就靠默认值，不显式写 source 列。
        // 实际占位符顺序（与 INSERT 列顺序对应）：
        //   timestamp, local_date, local_hour, model,
        //   input_tokens, cache_creation_input_tokens,
        //   cache_read_input_tokens, output_tokens, total_context,
        //   msg_count, session_id, cwd, project, source_file, provider
        let insertSQL = """
        INSERT INTO usage
        (timestamp, local_date, local_hour, model,
         input_tokens, cache_creation_input_tokens,
         cache_read_input_tokens, output_tokens, total_context,
         msg_count, session_id, cwd, project, source_file, provider)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        let upsertFilesSQL = """
        INSERT INTO files (path, mtime, size, records)
        VALUES (?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET
          mtime=excluded.mtime, size=excluded.size, records=excluded.records
        """

        // 整轮 sync 包一个大事务（批量提交，减少 fsync）。
        // Python 默认每语句提交一次，但移植版显式包事务对结果等价且更快。
        db.transaction {
            let insertStmt = db.prepare(insertSQL)
            let upsertFilesStmt = db.prepare(upsertFilesSQL)

            for (file, project) in files {
                stats.scanned += 1
                let pathStr = file.path
                seenPaths.insert(pathStr)

                // 取文件签名
                guard let sig = ClaudeJSONLParser.fileSignature(at: file) else {
                    stats.errors += 1
                    continue
                }

                let prev = knownFiles[pathStr]
                if let prev, !force, prev.mtime == sig.mtime, prev.size == sig.size {
                    stats.skipped += 1
                    continue
                }

                // 文件变了：先快照 (timestamp, provider) 仅非空，再 DELETE 旧行
                var providerSnapshots: [String: String] = [:]  // timestamp → provider
                if let prev {
                    db.query(
                        "SELECT timestamp, provider FROM usage WHERE source_file=?",
                        params: [pathStr]
                    ) { row in
                        let ts = row.string(at: 0)
                        let prov = row.string(at: 1)
                        if !prov.isEmpty {
                            providerSnapshots[ts] = prov
                        }
                    }
                    db.execute(
                        "DELETE FROM usage WHERE source_file=?", params: [pathStr]
                    )
                    stats.updated += 1
                } else {
                    stats.newFiles += 1
                }

                // 解析行
                let records = ClaudeJSONLParser.parseFile(at: file, project: project)

                for rec in records {
                    guard let parts = localParts(fromISO: rec.timestamp) else {
                        stats.errors += 1
                        continue
                    }
                    let total = rec.inputTokens
                        + rec.cacheCreationInputTokens
                        + rec.cacheReadInputTokens
                    // provider 沿用快照非空值，否则用当前 baseURL
                    let keep = providerSnapshots[rec.timestamp]
                    let providerVal = keep ?? currentBaseURL

                    let params: [Any?] = [
                        rec.timestamp,
                        parts.date,
                        parts.hour,
                        rec.model,
                        rec.inputTokens,
                        rec.cacheCreationInputTokens,
                        rec.cacheReadInputTokens,
                        rec.outputTokens,
                        total,
                        1,
                        rec.sessionID,
                        rec.cwd,
                        rec.project,
                        rec.sourceFile,
                        providerVal,
                    ]
                    db.stepOnce(insertStmt, params: params)
                    stats.records += 1
                }

                // UPSERT files 表
                db.stepOnce(
                    upsertFilesStmt,
                    params: [pathStr, sig.mtime, sig.size, records.count]
                )
            }

            // 4. 清理消失的文件
            if !knownFiles.isEmpty {
                let deleted = Set(knownFiles.keys).subtracting(seenPaths)
                for pathStr in deleted {
                    db.execute("DELETE FROM usage WHERE source_file=?", params: [pathStr])
                    db.execute("DELETE FROM files WHERE path=?", params: [pathStr])
                    stats.updated += 1
                }
            }
        }

        // 5. 写 meta.last_sync
        db.setMeta("last_sync", currentUTCISO())

        return stats
    }

    private static func currentUTCISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
