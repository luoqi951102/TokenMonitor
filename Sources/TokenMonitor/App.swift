import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct TokenMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - 全局崩溃诊断：捕获 ObjC exception + 信号，写出栈到容器诊断文件
//
// SwiftUI 布局异常（_crashOnException → CollectingViewsWithInvalidBaselines）
// 默认 macOS 不打印出 exception name + callstack 到 crashlog 里，看不到根因。
// 启动时设全局 NSExceptionHandler，_crashOnException 调起前先把异常详情 dump 到
// 容器 Documents/crash_diag.txt，下次崩了直接 cat 文件看精确异常名 + 栈。

private func installCrashDiagnostics() {
    // ObjC exception handler（SwiftUI 内部 _crashOnException 走的就是这条）
    NSSetUncaughtExceptionHandler { exception in
        var lines: [String] = []
        lines.append("=== ObjC NSException @ \(Date()) ===")
        lines.append("name: \(exception.name.rawValue)")
        lines.append("reason: \(exception.reason ?? "(nil)")")
        lines.append("userInfo: \(String(describing: exception.userInfo))")
        lines.append("--- callStackSymbols ---")
        for s in exception.callStackSymbols { lines.append(s) }
        let path = NSHomeDirectory() + "/Documents/crash_diag.txt"
        let content = lines.joined(separator: "\n") + "\n\n"
        // append 而非覆盖（保留历史多次崩的记录）
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            try? (existing + "\n" + content).write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    // Unix signal handler（backstop：信号也截）
    for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
        signal(sig) { sig in
            let name: String
            switch sig {
            case SIGABRT: name = "SIGABRT"
            case SIGSEGV: name = "SIGSEGV"
            case SIGBUS:  name = "SIGBUS"
            case SIGILL:  name = "SIGILL"
            case SIGFPE:  name = "SIGFPE"
            default:      name = "SIG\(sig)"
            }
            let stack = Thread.callstackSymbols.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
            let content = "=== Signal \(name) @ \(Date()) ===\n\(stack)\n\n"
            let path = NSHomeDirectory() + "/Documents/crash_diag.txt"
            if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
                try? (existing + "\n" + content).write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                try? content.write(toFile: path, atomically: true, encoding: .utf8)
            }
            // 让默认 handler 走（写 .ips crash report）
            signal(sig, SIG_DFL)
            raise(sig)
        }
    }
}

extension Thread {
    /// callStackSymbols 的帮扶 wrapper（命名一致性）
    static var callstackSymbols: [String] { callStackSymbols }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先装崩溃诊断（任何后续 SwiftUI layout 异常都会写到容器诊断文件）
        installCrashDiagnostics()

        // 一次性清理：旧版 ccusage.db 单文件 bookmark（key="bookmark_ccusage_db"），
        // 0.2.0 起改成 .claude 目录授权（key="bookmark_claude_dir"）以解决 sandbox
        // 下 SQLite 写 -wal/-shm 副文件被拒的问题。旧 bookmark 不清掉会 stale，但仍
        // 占 UserDefaults 空间，且 may 让老用户混淆 → 启动即清。
        BookmarkStore.clearStaleFileBookmarkIfAny()

        menuBarManager = MenuBarManager()
        menuBarManager?.bootstrap()

        // 系统休眠/唤醒：暂停/恢复定时刷新
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarManager?.cleanup()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - URL Scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "tokenmonitor" else { return }
        menuBarManager?.handleDeepLink(url: url)
    }

    // MARK: - System Events

    @objc private func systemWillSleep() {
        menuBarManager?.viewModel.syncRunner.stopTimer()
    }

    @objc private func systemDidWake() {
        menuBarManager?.viewModel.syncRunner.startTimer()
        Task { await menuBarManager?.viewModel.manualSync() }
    }
}
