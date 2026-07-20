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
    private static let snapshotFilename = "widget_snapshot.json"

    /// 从 App Group 容器目录读 JSON 文件（不用 UserDefaults，避免 sandbox 拒绝）
    private func loadSnapshot() -> WidgetSnapshot? {
        let log = WidgetLogger.shared
        log.append("loadSnapshot: begin")

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else {
            log.append("loadSnapshot: ❌ containerURL returned nil")
            return nil
        }
        log.append("loadSnapshot: containerURL = \(containerURL.path)")

        let fileURL = containerURL.appendingPathComponent(Self.snapshotFilename)
        log.append("loadSnapshot: fileURL = \(fileURL.path)")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            log.append("loadSnapshot: ❌ file not found")
            return nil
        }
        log.append("loadSnapshot: file exists")

        guard let data = try? Data(contentsOf: fileURL) else {
            log.append("loadSnapshot: ❌ cannot read data")
            return nil
        }
        log.append("loadSnapshot: read \(data.count) bytes")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let snap = try decoder.decode(WidgetSnapshot.self, from: data)
            log.append("loadSnapshot: ✅ decoded, totalTokens=\(snap.totalTokens)")
            return snap
        } catch {
            log.append("loadSnapshot: ❌ decode failed: \(error)")
            return nil
        }
    }

    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), snapshot: loadSnapshot(), hasData: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        WidgetLogger.shared.append("getSnapshot called")
        completion(WidgetEntry(date: Date(), snapshot: loadSnapshot(), hasData: true))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        WidgetLogger.shared.append("getTimeline called")
        let snap = loadSnapshot()
        let entry = WidgetEntry(date: Date(), snapshot: snap, hasData: true)
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        WidgetLogger.shared.append("getTimeline: returning timeline, hasSnapshot=\(snap != nil)")
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

/// Widget 端日志：写到 App Group 容器里的 widget_debug.log 文件
/// （主 App 可以读，便于诊断 widget 加载流程）
final class WidgetLogger {
    static let shared = WidgetLogger()
    private let appGroup = "N5YV5FV235.group.com.luoqi.tokenmonitor"
    private let filename = "widget_debug.log"

    func append(_ msg: String) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return }
        let url = containerURL.appendingPathComponent(filename)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
