import Foundation

// MARK: - Backfiller
//
// 集中三个运维命令的 Swift 实现，移植自 token-count/ccusage/db.py：
//   1. backfillProvider — 单信号源（msgid 指纹）回填空 provider
//   2. reconcileProviders — 双信号源（msgid + 路由窗）决策矩阵
//   3. dedupeClaudeRows — 临时表 + MIN(rowid) 去重重复行
//
// 三个命令都支持 dry-run（只报影响不写库），UI 先 preview 再让用户确认执行。
// 返回 Report struct，配合 sheet 展示结果。
//
// 读写都走 CCUsageDB（同一个可写句柄）；扫 JSONL 用 MSGIDScanner（独立于 ClaudeSync
// 因为这里只取 timestamp + message.id + model 三维，不取 token）。

// MARK: - 共享：msgid 扫描器

/// 扫 Claude JSONL 提取 (timestamp, message.id, model) 索引。
/// 与 backfill_provider / reconcile_providers 的扫描逻辑对齐。
enum MSGIDScanner {

    struct Entry {
        let model: String
        let msgID: String
    }

    /// 扫所有 jsonl，返回 timestamp → (model, msgid) 字典。
    /// 与 Python 一致：跳过 type≠assistant / 缺 model / 缺 timestamp / model∈ignored 的行。
    /// projectsDirURL 必须已是 security-scoped 持锁状态。
    static func scan(projectsDirURL: URL) -> (index: [String: Entry], scanned: Int, matched: Int, unmatched: Int, unmatchedSeens: [String: Int]) {
        var index: [String: Entry] = [:]
        var scanned = 0, matched = 0, unmatched = 0
        var unmatchedSeens: [String: Int] = [:]  // key = "model|prefix24"

        let files = ClaudeJSONLParser.iterJSONLFiles(
            projectsDir: projectsDirURL, securityScoped: true
        )

        for (file, _) in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
                var b = Array(line)
                while let last = b.last, last == 0x0D || last == 0x20 || last == 0x09 { b.removeLast() }
                while let first = b.first, first == 0x20 || first == 0x09 { b.removeFirst() }
                if b.isEmpty { continue }
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(b)) as? [String: Any] else { continue }
                guard (parsed["type"] as? String) == "assistant" else { continue }
                guard let msg = parsed["message"] as? [String: Any] else { continue }
                let model = msg["model"] as? String ?? ""
                if model.isEmpty || model == "<synthetic>" { continue }
                guard let ts = parsed["timestamp"] as? String, !ts.isEmpty else { continue }
                let mid = msg["id"] as? String ?? ""
                scanned += 1
                // 注意：Backfiller 的"matched"由调用方根据 _classify_provider 判断，
                // 这里只提供 index。但为对齐 Python 报数，scan 内部也区分 matched/unmatched
                let url = ProviderClassifier.classifyProviderFromMsgID(mid, model: model)
                if !url.isEmpty {
                    index[ts] = Entry(model: model, msgID: mid)
                    matched += 1
                } else {
                    // 即使未命中也存入 index（reconcile 需要它走 route 信号）
                    index[ts] = Entry(model: model, msgID: mid)
                    unmatched += 1
                    let prefix = mid.isEmpty ? "<empty>" : String(mid.prefix(24))
                    let key = "\(model)|\(prefix)"
                    unmatchedSeens[key, default: 0] += 1
                }
            }
        }
        return (index, scanned, matched, unmatched, unmatchedSeens)
    }
}

// MARK: - 1) backfillProvider

struct BackfillReport {
    var scanned = 0
    var matched = 0
    var updated = 0
    var skippedTagged = 0
    var unmatched = 0
    var dryRun: Bool
    /// (model, baseURL) → 条数（dry-run 预览分布）
    var writeDist: [(model: String, url: String, count: Int)] = []
    /// 未匹配 msgid 的 (model, msgid前缀) → 条数
    var unmatchedDist: [(model: String, prefix: String, count: Int)] = []
}

enum Backfiller {

    // MARK: 1) backfillProvider —— 单信号源 msgid 指纹回填

    /// 扫所有 Claude JSONL 的 message.id 指纹，回填空 provider 历史 Claude 行。
    /// 只更新 provider='' 的行（已带标签的不动，避免覆盖新数据）。
    /// 用 timestamp 做 DB 关联键。
    static func backfillProvider(
        db: CCUsageDB,
        projectsDirURL: URL,
        dryRun: Bool = false
    ) -> BackfillReport {
        var report = BackfillReport(dryRun: dryRun)

        let (msgidIndex, scanned, _, unmatched, unmatchedSeens) = MSGIDScanner.scan(
            projectsDirURL: projectsDirURL
        )
        report.scanned = scanned
        report.unmatched = unmatched

        // matched = msgid 指纹命中的条数（scan 里把命中和未命中都存 index 了，需重算）
        // 重新算 writeDist：timestamp → (url, model)
        var writePlan: [(ts: String, url: String, model: String)] = []
        for (ts, entry) in msgidIndex {
            let url = ProviderClassifier.classifyProviderFromMsgID(entry.msgID, model: entry.model)
            if !url.isEmpty {
                writePlan.append((ts, url, entry.model))
                report.matched += 1
            }
        }

        // 分布聚合
        var dist: [String: Int] = [:]  // key = "model|url"
        for p in writePlan {
            let key = "\(p.model)|\(p.url)"
            dist[key, default: 0] += 1
        }
        report.writeDist = dist.map { kv in
            let parts = kv.key.split(separator: "|", maxSplits: 1).map(String.init)
            return (model: parts[0], url: parts[1], count: kv.value)
        }.sorted { $0.count > $1.count }

        // unmatched 分布
        report.unmatchedDist = unmatchedSeens.map { kv in
            let parts = kv.key.split(separator: "|", maxSplits: 1).map(String.init)
            return (model: parts[0], prefix: parts[1], count: kv.value)
        }.sorted { $0.count > $1.count }

        if dryRun {
            return report
        }

        // 实际写入：按 timestamp 走 WHERE，只更新 provider='' 的 Claude 行
        for p in writePlan {
            // 先查空 provider 行是否存在
            var rowid = -1
            db.query(
                "SELECT rowid FROM usage WHERE source='claude' AND timestamp=? AND provider=''",
                params: [p.ts]
            ) { row in
                rowid = row.int(at: 0)
            }
            if rowid < 0 {
                report.skippedTagged += 1
                continue
            }
            let changes = db.execute(
                "UPDATE usage SET provider=? WHERE source='claude' AND timestamp=? AND provider=''",
                params: [p.url, p.ts]
            )
            report.updated += changes
        }

        return report
    }

    // MARK: 2) reconcileProviders —— 双信号源决策

    enum ReconcilePrefer: String {
        case strict, msgid, route
    }

    enum ReconcileMode {
        case both           // 双信号（默认）
        case onlyMsgid
        case onlyRoute
    }

    struct ReconcileReport {
        var scanned = 0
        var verified = 0
        var msgidOnly = 0
        var routeOnly = 0
        var conflict = 0
        var conflictWritten = 0
        var unmatched = 0
        var updated = 0
        var skippedTagged = 0
        var prefer: ReconcilePrefer
        var dryRun: Bool
        /// 路由时间窗快照（start|end|baseURL）
        var routeWindows: [(start: String, end: String, url: String)] = []
        /// 冲突清单 (ts, model, msgid_url, route_url)
        var conflicts: [(ts: String, model: String, msgidURL: String, routeURL: String)] = []
        /// (model, decision_tag) → 条数
        var writeDist: [(model: String, tag: String, count: Int)] = []
    }

    /// 双信号源回填 Claude 历史 provider。
    /// - 主信号：message.id 格式指纹（请求级，精度高）
    /// - 辅信号：路由窗（VSCode log + settings.json mtime）
    /// - prefer: strict 主辅一致才写 / msgid (默认) 命中就用冲突也用 / route 路由命中就用
    static func reconcileProviders(
        db: CCUsageDB,
        projectsDirURL: URL,
        dryRun: Bool = false,
        mode: ReconcileMode = .both,
        prefer: ReconcilePrefer = .msgid
    ) -> ReconcileReport {
        var report = ReconcileReport(prefer: prefer, dryRun: dryRun)

        // 1) 构造路由窗
        let windows = RouteTimelineBuilder.buildTimeline()
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFmt.timeZone = TimeZone(identifier: "UTC")
        report.routeWindows = windows.map { w in
            (start: isoFmt.string(from: w.startUTC),
             end: isoFmt.string(from: w.endUTC),
             url: w.baseURL)
        }

        // 2) 扫 JSONL 提取 (timestamp, model, msgid)
        let (msgidIndex, scanned, _, _, _) = MSGIDScanner.scan(
            projectsDirURL: projectsDirURL
        )
        report.scanned = scanned

        // 3) 双信号源决策
        var writePlan: [(ts: String, url: String, tag: String, model: String)] = []

        for (ts, entry) in msgidIndex {
            guard let tsDate = parseUTCISO(ts) else { continue }

            let msgidURL = (mode == .onlyRoute) ? "" : ProviderClassifier.classifyProviderFromMsgID(entry.msgID, model: entry.model)
            let routeURL = (mode == .onlyMsgid) ? "" : RouteTimelineBuilder.routeURLAt(ts: tsDate, windows: windows)

            // 单信号模式
            if mode == .onlyMsgid {
                if !msgidURL.isEmpty {
                    report.msgidOnly += 1
                    writePlan.append((ts, msgidURL, "msgid_only", entry.model))
                } else {
                    report.unmatched += 1
                }
                continue
            }
            if mode == .onlyRoute {
                if !routeURL.isEmpty {
                    report.routeOnly += 1
                    writePlan.append((ts, routeURL, "route_only", entry.model))
                } else {
                    report.unmatched += 1
                }
                continue
            }

            // 双信号源决策
            if !msgidURL.isEmpty && !routeURL.isEmpty && msgidURL == routeURL {
                report.verified += 1
                writePlan.append((ts, msgidURL, "verified", entry.model))
            } else if !msgidURL.isEmpty && !routeURL.isEmpty && msgidURL != routeURL {
                report.conflict += 1
                report.conflicts.append((ts, entry.model, msgidURL, routeURL))
                if prefer == .msgid {
                    writePlan.append((ts, msgidURL, "conflict_prefer_msgid", entry.model))
                    report.conflictWritten += 1
                } else if prefer == .route {
                    writePlan.append((ts, routeURL, "conflict_prefer_route", entry.model))
                    report.conflictWritten += 1
                }
                // strict 不写
            } else if !msgidURL.isEmpty && routeURL.isEmpty {
                report.msgidOnly += 1
                writePlan.append((ts, msgidURL, "msgid_only", entry.model))
            } else if msgidURL.isEmpty && !routeURL.isEmpty {
                report.routeOnly += 1
                writePlan.append((ts, routeURL, "route_only", entry.model))
            } else {
                report.unmatched += 1
            }
        }

        // 聚合 writeDist
        var dist: [String: Int] = [:]
        for p in writePlan {
            let key = "\(p.model)|\(p.tag)"
            dist[key, default: 0] += 1
        }
        report.writeDist = dist.map { kv in
            let parts = kv.key.split(separator: "|", maxSplits: 1).map(String.init)
            return (model: parts[0], tag: parts[1], count: kv.value)
        }.sorted { $0.count > $1.count }

        if dryRun {
            return report
        }

        // 实际写入
        for p in writePlan {
            var rowid = -1
            db.query(
                "SELECT rowid FROM usage WHERE source='claude' AND timestamp=? AND provider=''",
                params: [p.ts]
            ) { row in
                rowid = row.int(at: 0)
            }
            if rowid < 0 {
                report.skippedTagged += 1
                continue
            }
            let changes = db.execute(
                "UPDATE usage SET provider=? WHERE source='claude' AND timestamp=? AND provider=''",
                params: [p.url, p.ts]
            )
            report.updated += changes
        }

        return report
    }

    // MARK: 3) dedupeClaudeRows

    struct DedupeReport {
        var beforeRows = 0
        var afterRows = 0
        var deletedRows = 0
        var beforeTotalTokens = 0
        var afterTotalTokens = 0
        var dryRun: Bool
        /// 倍率分布：n(每组重复数) → 组数
        var dupGroupsByCount: [(n: Int, groups: Int)] = []
    }

    /// 去掉 usage 表里 Claude 同 (source_file, timestamp) 的重复行。
    /// 保留每组最小 rowid（最早插入的），其余 Claude 重复行删除。
    /// ZCode 走 (source, ext_id) UNIQUE 索引，无重复不动。
    static func dedupeClaudeRows(
        db: CCUsageDB,
        dryRun: Bool = false
    ) -> DedupeReport {
        var report = DedupeReport(dryRun: dryRun)

        // 1) 当前总量
        report.beforeRows = db.scalar("SELECT COUNT(*) FROM usage WHERE source='claude'")
        report.beforeTotalTokens = db.scalar(
            "SELECT COALESCE(SUM(total_context + output_tokens), 0) FROM usage"
        )

        // 2) 重复倍率分布
        db.query("""
        SELECT n, COUNT(*) AS groups FROM (
          SELECT COUNT(*) AS n FROM usage WHERE source='claude'
          GROUP BY source_file, timestamp
        ) GROUP BY n ORDER BY n
        """) { row in
            report.dupGroupsByCount.append((n: row.int(at: 0), groups: row.int(at: 1)))
        }

        // 3) 待删除行数
        report.deletedRows = db.scalar("""
        SELECT COUNT(*) FROM usage
        WHERE source='claude' AND rowid NOT IN (
          SELECT MIN(rowid) FROM usage WHERE source='claude'
          GROUP BY source_file, timestamp
        )
        """)

        if dryRun {
            // 模拟去重后的 token 数
            report.afterTotalTokens = db.scalar("""
            SELECT COALESCE(SUM(total_context + output_tokens), 0) FROM usage
            WHERE (source='claude' AND rowid IN (
                    SELECT MIN(rowid) FROM usage WHERE source='claude'
                    GROUP BY source_file, timestamp
                  )) OR source != 'claude'
            """)
            report.afterRows = report.beforeRows - report.deletedRows
            return report
        }

        // 4) 实际去重：临时表收集最小 rowid → DELETE 不在其中的行
        //    临时表在当前连接作用域；用 _keep_rowids 名字（Python 同名）。
        db.exec("DROP TABLE IF EXISTS _keep_rowids")
        db.exec("""
        CREATE TEMP TABLE _keep_rowids AS
        SELECT MIN(rowid) AS rid FROM usage WHERE source='claude'
        GROUP BY source_file, timestamp
        """)
        let deleted = db.execute("""
        DELETE FROM usage WHERE source='claude' AND rowid NOT IN (SELECT rid FROM _keep_rowids)
        """)
        db.exec("DROP TABLE _keep_rowids")

        // 5) 去重后再算一次总量
        report.afterRows = db.scalar("SELECT COUNT(*) FROM usage WHERE source='claude'")
        report.afterTotalTokens = db.scalar(
            "SELECT COALESCE(SUM(total_context + output_tokens), 0) FROM usage"
        )
        report.deletedRows = deleted

        return report
    }

    // MARK: - Helpers

    private static func parseUTCISO(_ ts: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        if let d = f.date(from: ts) { return d }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        basic.timeZone = TimeZone(identifier: "UTC")
        return basic.date(from: ts)
    }
}
