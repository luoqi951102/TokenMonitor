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

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
