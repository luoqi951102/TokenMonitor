import Foundation
import WidgetKit

// MARK: - WidgetStore
//
// 通过 App Group 把快照写到 UserDefaults，供 Widget Extension 读取。
// 同时负责 reload timeline。
//
// App Group: N5YV5FV235.group.com.luoqi.tokenmonitor
// Widget kind: com.luoqi.tokenmonitor.widget

final class WidgetStore {
    static let shared = WidgetStore()
    static let appGroup = "N5YV5FV235.group.com.luoqi.tokenmonitor"
    static let widgetKind = "com.luoqi.tokenmonitor.widget"
    private static let snapshotKey = "widget_snapshot"

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroup)
    }

    var snapshot: WidgetSnapshot? {
        guard let data = sharedDefaults?.data(forKey: Self.snapshotKey) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        sharedDefaults?.set(data, forKey: Self.snapshotKey)
        sharedDefaults?.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    var lastSyncAt: Date? {
        snapshot?.lastSyncAt
    }
}
