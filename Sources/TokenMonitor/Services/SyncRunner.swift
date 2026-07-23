import Foundation
import AppKit

// MARK: - SyncRunner
//
// 异步调用 `cc-usage sync`，让 token-count 把 Claude JSONL + ZCode SQLite 增量同步到
// ~/.claude/ccusage.db。App 只读 DB，写入交给 Python。
//
// 同步策略：
//   - App 启动后异步触发一次
//   - 定时器每 N 分钟（默认 10 分钟）触发一次
//   - 用户可在设置里手动触发
//
// cc-usage 位置查找顺序：
//   1. Settings 里用户配置的路径
//   2. PATH 中的 `cc-usage`
//   3. `~/.local/bin/cc-usage`（token-count install.sh 的默认安装位置）

@MainActor
final class SyncRunner: ObservableObject {

    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isAvailable: Bool = false

    /// 最近一次 Swift sync 的统计（claude + zcode 两段），UI 展示用。
    @Published private(set) var lastStats: SyncReport?

    /// 用户在设置里配置的 cc-usage 路径（空则用自动探测的）
    @Published var ccUsageOverride: String = UserDefaults.standard.string(forKey: "cc_usage_path") ?? "" {
        didSet {
            UserDefaults.standard.set(ccUsageOverride, forKey: "cc_usage_path")
            refreshAvailability()
        }
    }

    /// 自动刷新间隔（分钟）
    @Published var intervalMinutes: Int = UserDefaults.standard.object(forKey: "sync_interval_minutes") as? Int ?? 5 {
        didSet {
            UserDefaults.standard.set(intervalMinutes, forKey: "sync_interval_minutes")
            restartTimer()
        }
    }

    private var timer: Timer?
    private var task: Task<Void, Never>?

    init() {
        refreshAvailability()
    }

    // MARK: - Availability

    /// 当前生效的 cc-usage 路径（找不到返回 nil）。
    /// 注意：sandbox 下 App 无法 spawn 外部 binary，sync 由用户在 App 外执行
    /// （命令行 `cc-usage sync` 或 launchd plist 定时执行）。
    /// 这里仅用于显示状态和"打开终端"功能。
    var resolvedCCUsagePath: String? {
        if let bookmarkURL = BookmarkStore.shared.resolve(.ccUsageExe) {
            let p = bookmarkURL.path
            BookmarkStore.shared.release(bookmarkURL)
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        if !ccUsageOverride.isEmpty {
            return FileManager.default.isExecutableFile(atPath: ccUsageOverride) ? ccUsageOverride : nil
        }
        if let path = findInPATH("cc-usage") { return path }
        let home = NSHomeDirectory()
        let candidate = "\(home)/.local/bin/cc-usage"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private func refreshAvailability() {
        isAvailable = resolvedCCUsagePath != nil
    }

    private func findInPATH(_ cmd: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(cmd)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Sync
    //
    // Swift sync 私有化接管逻辑：
    //   - 若三个授权齐全（projects 目录 / ZCode DB / ccusage DB），syncNow 走 runSwiftSync() 真同步
    //   - 否则维持旧的"假同步真刷新" fallback（数据由用户在终端跑 cc-usage sync 或 launchd 产出）
    //
    // runSwiftSync 全程长持有 projects 目录 + zcode DB 的 security-scoped URL，
    // 整轮 sync 完才 release——不在循环里高频 resolve/release（避免重蹈 W2 工具调用显示 0 的 bug）。

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil

        if SandboxAuthorizer.allGranted {
            // 真同步路径
            do {
                lastStats = try await runSwiftSync()
                lastSyncAt = Date()
            } catch {
                lastError = "Swift 同步失败：\(error.localizedDescription)"
            }
        } else {
            // fallback：sandbox 下未授权，只做视觉反馈
            try? await Task.sleep(nanoseconds: 300_000_000)
            lastSyncAt = Date()
        }

        isSyncing = false
        refreshAvailability()
    }

    /// Swift 端真同步：Claude JSONL 扫描 + ZCode 增量水位线，全写进 ccusage.db。
    /// 整轮 sync 期间长持有 security-scoped URL，sync 完才 release。
    /// 必须在后台跑（IO 密集），调用方负责切线程。
    nonisolated func runSwiftSync() async throws -> SyncReport {
        // 1. 长持有三个 security-scoped URL，整轮 sync 期间不复用、不释放
        //    projects 目录授权 (Key.claudeProjectsDir) → 扫 JSONL
        //    zcode DB 授权 (Key.zcodeDB) → 增量读 model_usage
        //    ccusage DB 授权 (Key.ccusageDB) → 可写句柄打开它
        // 注：CCUsageDB 内部自己 resolve/release .ccusageDB bookmark（init/deinit 配对），
        //     所以这里只额外长持有 projects 和 zcode 两个 URL。
        guard let projectsURL = BookmarkStore.shared.resolve(.claudeProjectsDir) else {
            throw SyncError.notAuthorized("Claude projects 目录未授权")
        }
        defer { BookmarkStore.shared.release(projectsURL) }

        guard let zcodeURL = BookmarkStore.shared.resolve(.zcodeDB) else {
            throw SyncError.notAuthorized("ZCode 数据库未授权")
        }
        defer { BookmarkStore.shared.release(zcodeURL) }

        // 2. 打开可写 ccusage.db 句柄
        guard let db = CCUsageDB(path: UsageDBPath.ccusageDefault) else {
            throw SyncError.dbOpenFailed(UsageDBPath.ccusageDefault)
        }
        defer { _ = db }  // db 出作用域自动 deinit（关闭句柄 + release bookmark）

        // 3. Claude JSONL 同步
        var report = SyncReport()
        report.claude = ClaudeSync.sync(db: db, projectsDirURL: projectsURL)

        // 4. ZCode model_usage 增量同步
        report.zcode = ZCodeSync.sync(db: db, zcodeDB: zcodeURL)

        return report
    }

    /// 在 Terminal.app 打开一个新窗口，预填 cc-usage sync 命令
    func openInTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "cc-usage sync"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                lastError = "打开终端失败：\(error[NSAppleScript.errorMessage] ?? "未知错误")"
            }
        }
    }

    private static func runSync(at path: String) async throws {
        // 保留方法以兼容（实际不调用），sandbox 下不执行
        return
    }

    // MARK: - Timer

    func startTimer() {
        restartTimer()
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        stopTimer()
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncNow()
            }
        }
    }
}

// MARK: - Sync Report / Error

/// 一轮 Swift sync 的统计汇总。UI 展示用（设置页同步卡片）。
struct SyncReport {
    var claude = ClaudeSyncStats()
    var zcode = ZCodeSyncStats()
}

enum SyncError: LocalizedError {
    case notAuthorized(String)
    case dbOpenFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let what): return "\(what)（请在设置里授权）"
        case .dbOpenFailed(let path): return "无法打开 \(path)"
        }
    }
}
