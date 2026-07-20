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
