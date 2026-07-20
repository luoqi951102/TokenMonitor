import WidgetKit
import Foundation

// MARK: - Shared Snapshot (与主 App 一致的 Codable 结构)

struct WidgetSnapshot: Codable {
    struct ModelUsage: Codable {
        let model: String
        let source: String
        let inputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
        let totalContextTokens: Int
        let msgCount: Int
        let toolCallCount: Int

        var totalTokens: Int { totalContextTokens + outputTokens }

        enum CodingKeys: String, CodingKey {
            case model, source
            case inputTokens = "input_tokens"
            case cacheCreationTokens = "cache_creation_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case outputTokens = "output_tokens"
            case totalContextTokens = "total_context_tokens"
            case msgCount = "msg_count"
            case toolCallCount = "tool_call_count"
        }
    }

    struct DailyTotal: Codable {
        let date: String
        let tokens: Int
        let toolCalls: Int
        let msgs: Int
    }

    let generatedAt: Date
    let range: String
    let source: String
    let totalTokens: Int
    let totalToolCalls: Int
    let totalMsgs: Int
    let topModels: [ModelUsage]
    let daily: [DailyTotal]
    let lastSyncAt: Date?
}

// MARK: - Timeline Entry

struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let hasData: Bool

    static let placeholder = WidgetEntry(date: Date(), snapshot: nil, hasData: false)
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    private static let appGroup = "N5YV5FV235.group.com.luoqi.tokenmonitor"
    private static let snapshotKey = "widget_snapshot"

    private func loadSnapshot() -> WidgetSnapshot? {
        guard let sharedDefaults = UserDefaults(suiteName: Self.appGroup),
              let data = sharedDefaults.data(forKey: Self.snapshotKey) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), snapshot: loadSnapshot(), hasData: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(WidgetEntry(date: Date(), snapshot: loadSnapshot(), hasData: true))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = WidgetEntry(date: Date(), snapshot: loadSnapshot(), hasData: true)
        // App 通过 WidgetCenter.reloadTimelines 主动驱动刷新，fallback 1 小时
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}
