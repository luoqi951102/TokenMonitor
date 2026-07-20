import Foundation

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
    var resolvedCCUsagePath: String? {
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

    func syncNow() async {
        guard !isSyncing else { return }
        guard let path = resolvedCCUsagePath else {
            lastError = "未找到 cc-usage 可执行文件（可在设置中手动指定路径）"
            isAvailable = false
            return
        }

        isSyncing = true
        lastError = nil

        let task = Task.detached(priority: .utility) { [path] in
            do {
                try await Self.runSync(at: path)
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
        self.task = task
        await task.value

        isSyncing = false
        lastSyncAt = Date()
        refreshAvailability()
    }

    private static func runSync(at path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "\(shellQuote(path)) sync"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let msg = String(data: data, encoding: .utf8) ?? "未知错误"
                        cont.resume(throwing: NSError(
                            domain: "SyncRunner",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "cc-usage sync 退出码 \(process.terminationStatus): \(msg.prefix(200))"]
                        ))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static nonisolated func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
