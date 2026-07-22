import Foundation

// MARK: - Aggregator
//
// 从 ccusage.db 读取并聚合用量数据。逻辑移植自 token-count ccusage/aggregate.py。
// 时区固定 Asia/Shanghai（与 ccusage 写入时分桶一致）。
// tool_call_count / reasoning_tokens 从 ZCodeUsageDB 补齐（仅 source=zcode 的行有效）。

final class Aggregator {
    let db: UsageDB
    let zcodeDB: ZCodeUsageDB?

    init(db: UsageDB, zcodeDB: ZCodeUsageDB? = nil) {
        self.db = db
        self.zcodeDB = zcodeDB
    }

    // MARK: - Timezone

    static let shanghai: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private static func shanghaiCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        cal.firstWeekday = 2  // 周一为一周第一天（与 aggregate.py weekday() 一致）
        return cal
    }

    // MARK: - Date Range Resolution

    struct DateRange {
        let start: String   // YYYY-MM-DD（含）
        let end: String     // YYYY-MM-DD（含）
        let label: String
    }

    func resolveRange(_ range: UsageRange) -> DateRange {
        let cal = Self.shanghaiCalendar()
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .weekday], from: now)
        let today = cal.startOfDay(for: now)

        func fmt(_ d: Date, with pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = Self.shanghai
            f.dateFormat = pattern
            return f.string(from: d)
        }

        switch range {
        case .today:
            let s = fmt(today, with: "yyyy-MM-dd")
            return DateRange(start: s, end: s, label: "今日 \(s)")
        case .week:
            // weekday: 1=Sunday ... 7=Saturday（firstWeekday=2 时 Calendar 仍按公历 weekday 返回）
            // aggregate.py 用 today.weekday() (Python: Mon=0)，等价于 (comps.weekday + 5) % 7
            let pyWeekday = ((comps.weekday ?? 1) + 5) % 7  // Mon=0 ... Sun=6
            let monday = cal.date(byAdding: .day, value: -pyWeekday, to: today)!
            let sunday = cal.date(byAdding: .day, value: 6, to: monday)!
            return DateRange(
                start: fmt(monday, with: "yyyy-MM-dd"),
                end: fmt(sunday, with: "yyyy-MM-dd"),
                label: "本周 \(fmt(monday, with: "MM-dd")) ~ \(fmt(sunday, with: "MM-dd"))"
            )
        case .month:
            let first = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1))!
            let nextMonth: Date = {
                if comps.month == 12 {
                    return cal.date(from: DateComponents(year: (comps.year ?? 2026) + 1, month: 1, day: 1))!
                }
                return cal.date(from: DateComponents(year: comps.year, month: (comps.month ?? 1) + 1, day: 1))!
            }()
            let last = cal.date(byAdding: .day, value: -1, to: nextMonth)!
            return DateRange(
                start: fmt(first, with: "yyyy-MM-dd"),
                end: fmt(last, with: "yyyy-MM-dd"),
                label: fmt(first, with: "yyyy-MM")
            )
        case .all:
            return DateRange(start: "2000-01-01", end: "2099-12-31", label: "全部历史")
        }
    }

    // MARK: - Source Filter

    /// 把 "all" / "claude" / "zcode" 转成 SQL 参数。
    /// 利用 ccusage 的小技巧：`AND (source = ? OR ? = 'all')` 双绑定。
    private func sourceParams(_ source: String) -> [Any?] {
        [source, source]
    }

    // MARK: - By Model (聚合区间内每个模型 + provider 总量)
    //
    // 当一个 model 有多个 provider（如 glm-5.2 来自智谱官方 + 自定义供应商），
    // 拆成多行显示。provider 为空时（Claude 日志）合并为一行。

    func models(in range: DateRange, sourceFilter: String = "all") -> [ModelUsage] {
        let sql = """
            SELECT model, source, provider,
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(cache_creation_input_tokens), 0),
                   COALESCE(SUM(cache_read_input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(total_context), 0),
                   COALESCE(SUM(msg_count), 0)
            FROM usage
            WHERE local_date BETWEEN ? AND ?
              AND (source = ? OR ? = 'all')
            GROUP BY model, source, provider
            ORDER BY SUM(total_context) DESC
            """

        var rows: [ModelUsage] = []
        db.query(
            sql,
            params: [range.start, range.end] + sourceParams(sourceFilter)
        ) { row in
            rows.append(ModelUsage(
                model: row.string(at: 0),
                source: row.string(at: 1),
                provider: row.string(at: 2),
                inputTokens: row.int(at: 3),
                cacheCreationTokens: row.int(at: 4),
                cacheReadTokens: row.int(at: 5),
                outputTokens: row.int(at: 6),
                totalContextTokens: row.int(at: 7),
                msgCount: row.int(at: 8),
                toolCallCount: 0
            ))
        }

        // 补 tool_call_count：按 (model, provider) 维度（zcode 来源行才有效）
        if let zcodeDB, sourceFilter == "all" || sourceFilter == "zcode" {
            // ZCodeUsageDB 当前按 model 聚合工具调用，没有 provider 维度
            // 这里用 model 维度近似（同一 model 的所有 provider 共享该 model 的工具调用数按比例分摊不现实，
            // 简化：tool_call_count 按 provider 的 msgCount 比例分配）
            let toolStats = zcodeDB.toolCallsByModel(start: range.start, end: range.end)
            // 按 model 分组，计算每个 model 的总 msgCount（用于按比例分摊）
            var modelTotalMsgs: [String: Int] = [:]
            for r in rows where r.source == "zcode" {
                modelTotalMsgs[r.model, default: 0] += r.msgCount
            }
            for i in rows.indices where rows[i].source == "zcode" {
                let stat = toolStats[rows[i].model]
                let totalTools = stat?.toolCalls ?? 0
                let totalMsgs = modelTotalMsgs[rows[i].model] ?? 1
                // 按 msgCount 比例分摊工具调用数到各 provider
                let shareTools = totalMsgs > 0 ? totalTools * rows[i].msgCount / totalMsgs : 0
                rows[i] = ModelUsage(
                    model: rows[i].model,
                    source: rows[i].source,
                    provider: rows[i].provider,
                    inputTokens: rows[i].inputTokens,
                    cacheCreationTokens: rows[i].cacheCreationTokens,
                    cacheReadTokens: rows[i].cacheReadTokens,
                    outputTokens: rows[i].outputTokens,
                    totalContextTokens: rows[i].totalContextTokens,
                    msgCount: rows[i].msgCount,
                    toolCallCount: shareTools
                )
            }
        }

        // 二次合并：把 displayWithProvider 相同的行合并（计数累加）。
        // 背景：Claude 历史日志没有 baseURL，provider 列为空；going-forward 后新行带 baseURL 标签。
        // 同一 model 的「空 provider 历史行 + baseURL 新行」会被 SQL GROUP BY 拆成两行，
        // 但 displayWithProvider 在两端都解析为同一友好名（如「glm-52-w4a8-kv · 词元之芯·Token工厂」），
        // 视觉上应合并为一行。合并后 provider 优先取非空（baseURL 标签更精确）。
        // 合并会改变总数，需重排以保证按 totalContextTokens 降序（与原 SQL ORDER BY 一致）。
        let merged = Self.mergeByDisplayProvider(rows)
        return merged.sorted { $0.totalContextTokens > $1.totalContextTokens }
    }

    /// 把 displayWithProvider 相同的 ModelUsage 行合并。
    /// - key: `<source>|<displayWithProvider>`（包含 model + 解析后的供应商名）
    /// - provider 字段：优先保留非空（baseURL/UUID/builtin 标签优于历史空推断）
    /// - 各计数（tokens/msgs/toolCalls）累加
    /// - 保留首次出现顺序（调用方按需重排）
    private static func mergeByDisplayProvider(_ rows: [ModelUsage]) -> [ModelUsage] {
        var grouped: [String: ModelUsage] = [:]
        var order: [String] = []
        for r in rows {
            let key = "\(r.source)|\(r.displayWithProvider)"
            if let existing = grouped[key] {
                grouped[key] = ModelUsage(
                    model: existing.model,
                    source: existing.source,
                    provider: existing.provider.isEmpty ? r.provider : existing.provider,
                    inputTokens: existing.inputTokens + r.inputTokens,
                    cacheCreationTokens: existing.cacheCreationTokens + r.cacheCreationTokens,
                    cacheReadTokens: existing.cacheReadTokens + r.cacheReadTokens,
                    outputTokens: existing.outputTokens + r.outputTokens,
                    totalContextTokens: existing.totalContextTokens + r.totalContextTokens,
                    msgCount: existing.msgCount + r.msgCount,
                    toolCallCount: existing.toolCallCount + r.toolCallCount
                )
            } else {
                grouped[key] = r
                order.append(key)
            }
        }
        return order.compactMap { grouped[$0] }
    }

    // MARK: - Daily Totals (区间内按日，跨模型)

    func dailyTotals(in range: DateRange, sourceFilter: String = "all") -> [DailyTotal] {
        let sql = """
            SELECT local_date,
                   COALESCE(SUM(total_context + output_tokens), 0),
                   COALESCE(SUM(msg_count), 0)
            FROM usage
            WHERE local_date BETWEEN ? AND ?
              AND (source = ? OR ? = 'all')
            GROUP BY local_date
            ORDER BY local_date
            """

        var rows: [DailyTotal] = []
        db.query(
            sql,
            params: [range.start, range.end] + sourceParams(sourceFilter)
        ) { row in
            rows.append(DailyTotal(
                date: row.string(at: 0),
                tokens: row.int(at: 1),
                toolCalls: 0,
                msgs: row.int(at: 2)
            ))
        }

        // 补工具调用（按日期）
        if let zcodeDB, sourceFilter == "all" || sourceFilter == "zcode" {
            let modelStats = zcodeDB.toolCallsByModel(start: range.start, end: range.end)
            // modelStats 没分日期，这里只能补区间合计；分日 tool_calls 需要扩展 ZCodeUsageDB
            // 简化：暂不补分日，置 0。如需分日，参见 dailyToolCalls 实现。
            _ = modelStats
        }

        return rows
    }

    /// 分日工具调用数（仅 zcode 来源）。
    func dailyToolCalls(in range: DateRange) -> [String: Int] {
        guard let zcodeDB else { return [:] }
        return zcodeDB.dailyToolCalls(start: range.start, end: range.end)
    }

    // MARK: - Hourly Distribution

    func hourly(in range: DateRange, sourceFilter: String = "all") -> [HourlyBucket] {
        let sql = """
            SELECT local_hour,
                   COALESCE(SUM(total_context), 0),
                   COALESCE(SUM(msg_count), 0)
            FROM usage
            WHERE local_date BETWEEN ? AND ?
              AND (source = ? OR ? = 'all')
            GROUP BY local_hour
            ORDER BY local_hour
            """
        var rows: [HourlyBucket] = []
        db.query(
            sql,
            params: [range.start, range.end] + sourceParams(sourceFilter)
        ) { row in
            rows.append(HourlyBucket(
                hour: row.int(at: 0),
                tokens: row.int(at: 1),
                msgs: row.int(at: 2)
            ))
        }
        return rows
    }

    // MARK: - Streak (连续打卡)

    struct StreakInfo {
        let current: Int
        let longest: Int
        let activeToday: Bool
    }

    func streak(sourceFilter: String = "all") -> StreakInfo {
        let sql = """
            SELECT DISTINCT local_date FROM usage
            WHERE (source = ? OR ? = 'all')
            ORDER BY local_date
            """
        var dates: [String] = []
        db.query(sql, params: sourceParams(sourceFilter)) { row in
            dates.append(row.string(at: 0))
        }
        if dates.isEmpty {
            return StreakInfo(current: 0, longest: 0, activeToday: false)
        }

        let cal = Self.shanghaiCalendar()
        let dateSet = Set(dates)
        let todayStr = Self.localDateString(from: Date(), calendar: cal)
        let activeToday = dateSet.contains(todayStr)

        // current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Self.shanghai
        f.dateFormat = "yyyy-MM-dd"
        var cursor = cal.startOfDay(for: Date())
        if !activeToday {
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        var current = 0
        while dateSet.contains(f.string(from: cursor)) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }

        // longest
        var longest = 0
        var run = 0
        var prev: Date? = nil
        for d in dates {
            let dt = f.date(from: d)!
            if let prev, cal.dateComponents([.day], from: prev, to: dt).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            prev = dt
        }

        return StreakInfo(current: current, longest: longest, activeToday: activeToday)
    }

    // MARK: - Week over Week

    struct WoWInfo {
        let thisWeek: Int
        let lastWeek: Int
        let deltaPct: Double?   // 上周为 0 则 nil
    }

    func weekOverWeek(sourceFilter: String = "all") -> WoWInfo {
        let this = resolveRange(.week)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let thisStart = f.date(from: this.start)!
        let thisEnd = f.date(from: this.end)!
        let cal = Self.shanghaiCalendar()
        let lastStart = cal.date(byAdding: .day, value: -7, to: thisStart)!
        let lastEnd = cal.date(byAdding: .day, value: -7, to: thisEnd)!

        func sum(_ s: String, _ e: String) -> Int {
            db.scalar(
                """
                SELECT COALESCE(SUM(total_context), 0) FROM usage
                WHERE local_date BETWEEN ? AND ?
                  AND (source = ? OR ? = 'all')
                """,
                params: [s, e] + sourceParams(sourceFilter)
            )
        }

        let tw = sum(f.string(from: thisStart), f.string(from: thisEnd))
        let lw = sum(f.string(from: lastStart), f.string(from: lastEnd))
        let delta: Double? = lw == 0 ? nil : Double(tw - lw) / Double(lw) * 100
        return WoWInfo(thisWeek: tw, lastWeek: lw, deltaPct: delta)
    }

    // MARK: - Source Breakdown

    struct SourceSplit {
        let claude: Int
        let zcode: Int
    }

    func sourceBreakdown(in range: DateRange) -> SourceSplit {
        let sql = """
            SELECT source, COALESCE(SUM(total_context), 0)
            FROM usage
            WHERE local_date BETWEEN ? AND ?
            GROUP BY source
            """
        var c = 0, z = 0
        db.query(sql, params: [range.start, range.end]) { row in
            let src = row.string(at: 0)
            let total = row.int(at: 1)
            if src == "claude" { c = total }
            if src == "zcode" { z = total }
        }
        return SourceSplit(claude: c, zcode: z)
    }

    // MARK: - Data Span

    func dataSpan() -> (start: String?, end: String?) {
        var start: String? = nil
        var end: String? = nil
        db.query("SELECT MIN(local_date), MAX(local_date) FROM usage") { row in
            start = row.isNull(at: 0) ? nil : row.string(at: 0)
            end = row.isNull(at: 1) ? nil : row.string(at: 1)
        }
        return (start, end)
    }

    // MARK: - Active Projects
    //
    // 按 cwd 维度聚合：看用户在哪些项目里用 LLM 多。
    // 路径转 ~ 格式（与 ccusage 报告一致），unknown 单独成项。

    struct ProjectStat: Identifiable {
        var id: String { project }
        let project: String
        let tokens: Int
        let msgs: Int
        let rows: Int
    }

    func activeProjects(in range: DateRange, sourceFilter: String = "all", limit: Int = 10) -> [ProjectStat] {
        let sql = """
            SELECT project,
                   COALESCE(SUM(total_context + output_tokens), 0),
                   COALESCE(SUM(msg_count), 0),
                   COUNT(*) AS rows
            FROM usage
            WHERE local_date BETWEEN ? AND ?
              AND (source = ? OR ? = 'all')
            GROUP BY project
            ORDER BY SUM(total_context) DESC
            LIMIT ?
            """
        var out: [ProjectStat] = []
        db.query(sql, params: [range.start, range.end] + sourceParams(sourceFilter) + [limit]) { row in
            let raw = row.string(at: 0)
            let project = Self.displayProject(raw)
            out.append(ProjectStat(
                project: project,
                tokens: row.int(at: 1),
                msgs: row.int(at: 2),
                rows: row.int(at: 3)
            ))
        }
        // 合并相同 project（不同绝对路径可能映射到相同 ~ 路径）
        var merged: [String: ProjectStat] = [:]
        for p in out {
            if var existing = merged[p.project] {
                existing = ProjectStat(
                    project: p.project,
                    tokens: existing.tokens + p.tokens,
                    msgs: existing.msgs + p.msgs,
                    rows: existing.rows + p.rows
                )
                merged[p.project] = existing
            } else {
                merged[p.project] = p
            }
        }
        return merged.values.sorted { $0.tokens > $1.tokens }
    }

    /// 路径转显示格式（与 ccusage active_projects 一致）
    /// - 空字符串 → (unknown)
    /// - /Users/luoqi → ~
    /// - /Users/luoqi/... → ~/...
    /// - 其他原样
    private static func displayProject(_ raw: String) -> String {
        let home = NSHomeDirectory()
        if raw.isEmpty { return "(unknown)" }
        if raw == home { return "~" }
        if raw.hasPrefix(home + "/") { return "~" + String(raw.dropFirst(home.count)) }
        return raw
    }

    // MARK: - Reasoning Tokens (bonus)

    /// 区间内各模型的 reasoning_tokens 总量（仅 ZCode 推理模型有值）。
    func reasoningTokensByModel(in range: DateRange) -> [String: Int] {
        zcodeDB?.reasoningTokensByModel(start: range.start, end: range.end) ?? [:]
    }

    // MARK: - Helpers

    private static func localDateString(from date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
