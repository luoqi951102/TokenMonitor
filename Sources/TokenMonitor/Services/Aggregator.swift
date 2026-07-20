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

    // MARK: - By Model (聚合区间内每个模型总量)

    /// 按 (source, model) 聚合，返回 ModelUsage 列表，按 totalContextTokens 降序。
    func models(in range: DateRange, sourceFilter: String = "all") -> [ModelUsage] {
        let sql = """
            SELECT model, source,
                   COALESCE(SUM(input_tokens), 0),
                   COALESCE(SUM(cache_creation_input_tokens), 0),
                   COALESCE(SUM(cache_read_input_tokens), 0),
                   COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(total_context), 0),
                   COALESCE(SUM(msg_count), 0)
            FROM usage
            WHERE local_date BETWEEN ? AND ?
              AND (source = ? OR ? = 'all')
            GROUP BY model, source
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
                inputTokens: row.int(at: 2),
                cacheCreationTokens: row.int(at: 3),
                cacheReadTokens: row.int(at: 4),
                outputTokens: row.int(at: 5),
                totalContextTokens: row.int(at: 6),
                msgCount: row.int(at: 7),
                toolCallCount: 0
            ))
        }

        // 补 tool_call_count：按 model 维度（zcode 来源行才有效）
        if let zcodeDB, sourceFilter == "all" || sourceFilter == "zcode" {
            let toolStats = zcodeDB.toolCallsByModel(start: range.start, end: range.end)
            for i in rows.indices where rows[i].source == "zcode" {
                let stat = toolStats[rows[i].model]
                let tools = stat?.toolCalls ?? 0
                rows[i] = ModelUsage(
                    model: rows[i].model,
                    source: rows[i].source,
                    inputTokens: rows[i].inputTokens,
                    cacheCreationTokens: rows[i].cacheCreationTokens,
                    cacheReadTokens: rows[i].cacheReadTokens,
                    outputTokens: rows[i].outputTokens,
                    totalContextTokens: rows[i].totalContextTokens,
                    msgCount: rows[i].msgCount,
                    toolCallCount: tools
                )
            }
        }

        return rows
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
