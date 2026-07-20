import Foundation
import WidgetKit

// MARK: - WidgetStore
//
// 通过 App Group 把快照传给 Widget Extension。
//
// 重要：不用 UserDefaults(suiteName:) -- 在 ad-hoc 签名 + sandbox=true 下，
// widget 进程读 App Group 的 UserDefaults plist 会被 sandbox 拒绝：
//   "accessing preferences outside an application's container requires
//    user-preference-read or file-read-data sandbox access"
//
// 改用文件方式：snapshot 写成 JSON 文件放到 App Group 容器目录，
// widget 用 FileManager 直接读 JSON 文件（sandbox 允许 App Group 容器内文件 IO）。
//
// App Group: N5YV5FV235.group.com.luoqi.tokenmonitor
// Widget kind: com.luoqi.tokenmonitor.widget

final class WidgetStore {
    static let shared = WidgetStore()
    static let appGroup = "N5YV5FV235.group.com.luoqi.tokenmonitor"
    static let widgetKind = "com.luoqi.tokenmonitor.widget"
    private static let snapshotFilename = "widget_snapshot.json"

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]  // 稳定输出便于 diff
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// App Group 容器目录 URL。
    /// sandbox 下 FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)
    /// 会返回该 App Group 的真实路径（widget 和主 App 都能访问）。
    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
    }

    private var snapshotFileURL: URL? {
        containerURL?.appendingPathComponent(Self.snapshotFilename)
    }

    /// 读取 snapshot（widget 用，主 App 也可用）
    var snapshot: WidgetSnapshot? {
        guard let url = snapshotFileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    var lastSyncAt: Date? {
        snapshot?.lastSyncAt
    }

    /// 写入 snapshot 并触发 widget reload
    func save(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotFileURL else { return }
        // 写到临时文件再原子替换，避免 widget 读到半写状态
        guard let data = try? encoder.encode(snapshot) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // fallback：直接写
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }
}
