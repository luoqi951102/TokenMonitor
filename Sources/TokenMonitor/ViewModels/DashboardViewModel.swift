import Foundation
import Combine

// MARK: - Dashboard ViewModel
//
// 核心状态管理层：
// 1. 通过 SyncRunner 驱动 cc-usage sync 写入 DB
// 2. 通过 Aggregator 从 ccusage.db 只读聚合
// 3. 对外暴露 @Published 属性供 UI 绑定
// 4. range / source 切换时重新聚合
// 5. 数据同步后写 WidgetStore 推送给小组件

@MainActor
final class DashboardViewModel: ObservableObject {

    // MARK: - Filters

    @Published var range: UsageRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "default_range"); refresh() }
    }
    @Published var source: String {   // "all" | "claude" | "zcode"
        didSet { UserDefaults.standard.set(source, forKey: "default_source"); refresh() }
    }

    // MARK: - Aggregated State

    @Published private(set) var models: [ModelUsage] = []
    @Published private(set) var daily: [DailyTotal] = []
    @Published private(set) var hourly: [HourlyBucket] = []
    @Published private(set) var streak: Aggregator.StreakInfo = .init(current: 0, longest: 0, activeToday: false)
    @Published private(set) var wow: Aggregator.WoWInfo = .init(thisWeek: 0, lastWeek: 0, deltaPct: nil)
    @Published private(set) var rangeLabel: String = ""

    // MARK: - Sync State

    // SyncRunner 是 ObservableObject，作为子对象发布。SettingsView 通过 viewModel.syncRunner 直接观察。
    @Published var syncRunner = SyncRunner()
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var dataSpan: (start: String?, end: String?) = (nil, nil)

    // MARK: - Errors

    @Published private(set) var errorMessage: String?
    @Published private(set) var hasDB: Bool = false

    // MARK: - Aggregator

    private var aggregator: Aggregator?
    /// 上次 openDB 时记录的 ccusage.db mtime，用于 refresh() 时判断是否需要重建。
    /// 高频路径（5min timer / 浮窗刷新按钮）不需要每次重建 aggregator，
    /// 否则会反复 resolve/release security-scoped bookmark，
    /// 在 sandbox 下间歇读不到 ZCode 库（工具调用显示 0 的 bug 根因）。
    private var lastSeenCCUsageMtime: Date? = nil

    // MARK: - Init

    init() {
        let savedRange = UserDefaults.standard.string(forKey: "default_range").flatMap(UsageRange.init(rawValue:)) ?? .today
        let savedSource = UserDefaults.standard.string(forKey: "default_source") ?? "all"
        self.range = savedRange
        self.source = savedSource
    }

    // MARK: - DB Setup

    /// 打开 DB（ccusage.db + ZCode db），失败也优雅降级。
    func openDB() {
        let ccusagePath = UsageDBPath.ccusageDefault
        if let db = UsageDB(path: ccusagePath) {
            let zcode = ZCodeUsageDB(path: UsageDBPath.zcodeDefault)
            aggregator = Aggregator(db: db, zcodeDB: zcode)
            hasDB = true
            dataSpan = aggregator?.dataSpan() ?? (nil, nil)
            lastSeenCCUsageMtime = ccusageMtime()
        } else {
            aggregator = nil
            hasDB = false
            lastSeenCCUsageMtime = nil
        }
    }

    /// 只在 ccusage.db mtime 变化时重建 aggregator，避免高频路径反复
    /// resolve/release security-scoped bookmark 引起 ZCode 句柄间歇性失效。
    private func reopenDBIfChanged() {
        let now = ccusageMtime()
        guard now != lastSeenCCUsageMtime else { return }
        openDB()
    }

    private func ccusageMtime() -> Date? {
        let resolvedPath: String
        if let dirURL = BookmarkStore.shared.resolve(.ccusageDB) {
            defer { BookmarkStore.shared.release(dirURL) }
            resolvedPath = UsageDBPath.ccusagePath(in: dirURL)
        } else {
            resolvedPath = UsageDBPath.ccusageDefault
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
        return attrs?[.modificationDate] as? Date
    }

    // MARK: - Lifecycle

    func bootstrap() {
        openDB()
        syncRunner.startTimer()
        Task {
            await syncRunner.syncNow()
            reopenDBIfChanged()  // sync 完成后看 DB 有没有被新建/改写
            refresh()
            pushWidgetSnapshot()
        }
        refresh()  // 立即用现有缓存数据展示
    }

    func shutdown() {
        syncRunner.stopTimer()
    }

    // MARK: - Refresh

    func refresh() {
        // refresh 高频被调用（5min timer / 浮窗刷新按钮 / menu close 后 reopen 等）
        // 不能每次都重建 aggregator —— 仅在 ccusage.db mtime 变化时才重建。
        // 否则 ZCodeUsageDB 的 security-scoped bookmark 会被反复 resolve/release，
        // 在 sandbox 下间歇性读到 nil，导致工具调用显示 0 的 bug。
        reopenDBIfChanged()

        guard let aggregator else {
            errorMessage = hasDB ? "数据库未就绪" : "未找到 ~/.claude/ccusage.db，请先运行 cc-usage sync"
            return
        }
        errorMessage = nil
        isLoading = true

        let r = aggregator.resolveRange(range)
        let src = source
        rangeLabel = r.label

        // 同步聚合（SQLite 查询很快，无需切后台）
        models = aggregator.models(in: r, sourceFilter: src)
        daily = aggregator.dailyTotals(in: r, sourceFilter: src)

        // 补工具调用数（分日）
        if src == "all" || src == "zcode" {
            let toolCalls = aggregator.dailyToolCalls(in: r)
            daily = daily.map { d in
                DailyTotal(date: d.date, tokens: d.tokens, toolCalls: toolCalls[d.date] ?? 0, msgs: d.msgs)
            }
        }

        hourly = aggregator.hourly(in: r, sourceFilter: src)
        streak = aggregator.streak(sourceFilter: src)
        wow = aggregator.weekOverWeek(sourceFilter: src)
        dataSpan = aggregator.dataSpan()
        lastUpdated = Date()
        isLoading = false
    }

    // MARK: - Manual Sync
    //
    // Swift sync 私有化后：syncNow 在三授权齐全时跑 ClaudeSync + ZCodeSync 真同步，
    // 把 JSONL + ZCode model_usage 增量写进 ccusage.db，不再依赖外部 Python cc-usage。
    // 未授权则走 fallback（数据由终端 cc-usage sync 或 launchd 产出）。
    //
    // 注意：openDB 会销毁旧 aggregator 并重建 UsageDB/ZCodeUsageDB 实例。
    // 高频路径（5 分钟 timer / 浮窗刷新按钮）请只调 refresh()，不要走 openDB()，
    // 否则会反复 resolve/release security-scoped bookmark 引起 sandbox
    // 间歇性读不到 ZCode 库（工具调用显示 0 的 bug 根因）。

    func manualSync() async {
        await syncRunner.syncNow()
        // Swift sync 一定会改 ccusage.db，强制 openDB 重建只读句柄（确保读到新数据）
        openDB()
        refresh()
        pushWidgetSnapshot()
    }

    // MARK: - Computed

    /// 当前范围 + 源的总 token
    var totalTokens: Int {
        models.reduce(0) { $0 + $1.totalTokens }
    }

    /// 当前范围 + 源的总 context token（不含 output）
    var totalContext: Int {
        models.reduce(0) { $0 + $1.totalContextTokens }
    }

    var totalOutput: Int {
        models.reduce(0) { $0 + $1.outputTokens }
    }

    var totalToolCalls: Int {
        models.reduce(0) { $0 + $1.toolCallCount }
    }

    var totalMsgs: Int {
        models.reduce(0) { $0 + $1.msgCount }
    }

    /// Top N 模型（按 totalTokens）
    func topModels(_ n: Int = 5) -> [ModelUsage] {
        Array(models.prefix(n))
    }

    /// 当前 range + source 下的 Top N 项目（按 context tokens）
    func topProjects(_ n: Int = 5) -> [Aggregator.ProjectStat] {
        guard let aggregator else { return [] }
        let r = aggregator.resolveRange(range)
        return Array(aggregator.activeProjects(in: r, sourceFilter: source, limit: n).prefix(n))
    }

    /// 来源占比
    var sourceSplit: Aggregator.SourceSplit? {
        guard let aggregator else { return nil }
        let r = aggregator.resolveRange(range)
        return aggregator.sourceBreakdown(in: r)
    }

    /// 推理 token 按模型（用于模型对比页 bonus）
    var reasoningByModel: [String: Int] {
        guard let aggregator else { return [:] }
        let r = aggregator.resolveRange(range)
        return aggregator.reasoningTokensByModel(in: r)
    }

    // MARK: - Widget

    func pushWidgetSnapshot() {
        let snapshot = WidgetSnapshot(
            generatedAt: Date(),
            range: range.rawValue,
            source: source,
            totalTokens: totalTokens,
            totalToolCalls: totalToolCalls,
            totalMsgs: totalMsgs,
            topModels: topModels(5),
            daily: Array(daily.suffix(14)),
            lastSyncAt: syncRunner.lastSyncAt
        )
        WidgetStore.shared.save(snapshot)
    }

    // MARK: - Formatters

    var lastUpdatedFormatted: String {
        guard let date = lastUpdated else { return "尚未刷新" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: date)
    }

    var syncStatusText: String {
        if syncRunner.isSyncing { return "同步中…" }
        if let last = syncRunner.lastSyncAt {
            let interval = Date().timeIntervalSince(last)
            if interval < 60 { return "刚刚同步" }
            if interval < 3600 { return "\(Int(interval / 60)) 分钟前同步" }
            return "\(Int(interval / 3600)) 小时前同步"
        }
        return hasDB ? "尚未同步" : "未连接"
    }
}
