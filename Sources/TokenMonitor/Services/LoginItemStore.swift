import Foundation
import AppKit
import ServiceManagement

// MARK: - LoginItemStore
//
// 用 SMAppService.mainApp（macOS 13+）注册/取消"登录项"。
// 注册后用户在「系统设置 → 通用 → 登录项」里能看到 Token Monitor，可以手动开关。
//
// 不需要额外 entitlement，sandbox App 可用。

@MainActor
final class LoginItemStore: ObservableObject {
    static let shared = LoginItemStore()

    @Published private(set) var isEnabled: Bool = false
    @Published var errorMessage: String?

    private init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
        case .requiresApproval:
            // 已注册但用户未在系统设置里批准
            isEnabled = true
        case .notRegistered, .notFound:
            isEnabled = false
        @unknown default:
            isEnabled = false
        }
    }

    /// 注册为登录项（status == .enabled 表示成功）
    @discardableResult
    func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            refresh()
            errorMessage = nil
            return isEnabled
        } catch {
            errorMessage = "注册登录项失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 取消登录项
    @discardableResult
    func disable() -> Bool {
        do {
            try SMAppService.mainApp.unregister()
            refresh()
            errorMessage = nil
            return !isEnabled
        } catch {
            errorMessage = "取消登录项失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 打开「系统设置 → 通用 → 登录项」（让用户手动批准 / 查看）
    func openSystemSettings() {
        // macOS 13+ 通用登录项设置 URL
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
