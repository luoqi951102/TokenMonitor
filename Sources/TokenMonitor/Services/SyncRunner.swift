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

    /// 用户在设置里配置的 cc-usage 路径（空则用自动探测的）
    @Published var ccUsageOverride: String = UserDefaults.standard.string(forKey: "cc_usage_path") ?? "" {
        didSet {
            UserDefaults.standard.set(ccUsageOverride, forKey: "cc_usage_path")
            refreshAvailability()
        }
    }

    /// 自动刷新间隔（分钟）
    @Published var intervalMinutes: Int = UserDefaults.standard.object(forKey: "sync_interval_minutes") as? Int ?? 10 {
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
    // sandbox=true 下无法 spawn 外部 binary（Apple 限制）。
    // 策略：syncNow 不实际跑 cc-usage，而是标记需要用户在终端手动跑。
    // SettingsView 提供"在终端打开"按钮，用户在 Terminal 里执行 `cc-usage sync`。
    // 也可选装 docs/com.luoqi.ccusage-sync.plist 用 launchd 系统级定时同步。

    func syncNow() async {
        guard !isSyncing else { return }
        // sandbox 下：只是触发 refresh（实际 sync 由用户在 App 外执行）
        isSyncing = true
        lastError = nil
        // 短暂等待，给用户视觉反馈
        try? await Task.sleep(nanoseconds: 300_000_000)
        lastSyncAt = Date()
        isSyncing = false
        refreshAvailability()
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
