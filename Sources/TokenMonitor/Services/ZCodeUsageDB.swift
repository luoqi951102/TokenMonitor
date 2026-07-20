import Foundation
import SQLite3

// MARK: - ZCodeUsageDB
//
// 只读访问 ~/.zcode/cli/db/db.sqlite 的 model_usage 表，补齐 ccusage.db 不存的两列：
//   - tool_call_count（工具调用次数）
//   - reasoning_tokens（推理 token）
//
// 关联键：ccusage.usage.ext_id = ZCode.model_usage.id（zcode 来源行）。
// 但 ext_id 跨库 JOIN 复杂，且 widget/对比视图只需按 (model, 日期范围) 聚合的工具调用数。
// 所以这里直接按 (model_id, started_at→local_date) 聚合。
//
// started_at 是毫秒级 epoch（参考 token-count ccusage/db.py:_local_parts_epoch）。
// ZCode 时区固定 Asia/Shanghai（与 ccusage 一致）。

final class ZCodeUsageDB {
    private var handle: OpaquePointer?
    let path: String

    init?(path: String) {
        self.path = path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let candidates = [
            "file:\(path)?immutable=1",
            "file:\(path)?mode=ro",
        ]
        for url in candidates {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            if sqlite3_open_v2(url, &db, flags, nil) == SQLITE_OK {
                self.handle = db
                return
            }
            sqlite3_close(db)
        }
        return nil
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    var isOpen: Bool { handle != nil }

    // MARK: - 时区（Asia/Shanghai）

    private static let shanghai: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    /// 毫秒 epoch → 上海时区 "YYYY-MM-DD"
    private static func localDateString(fromMs ms: Int64) -> String? {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    // MARK: - Tool Call Aggregation

    struct ToolStat {
        let model: String
        let toolCalls: Int
        let msgs: Int
    }

    /// 查询区间内（含）按模型聚合的工具调用数 + 消息数。
    /// 过滤 status='completed'（与 ccusage.sync_zcode 一致）。
    func toolCallsByModel(start: String, end: String) -> [String: ToolStat] {
        guard let handle else { return [:] }
        var stmt: OpaquePointer?
        let sql = """
            SELECT model_id, started_at, tool_call_count
            FROM model_usage
            WHERE status = 'completed' AND started_at IS NOT NULL
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: ToolStat] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = String(cString: sqlite3_column_text(stmt, 0))
            let startedMs = sqlite3_column_int64(stmt, 1)
            let tools = Int(sqlite3_column_int64(stmt, 2))
            guard let dateStr = Self.localDateString(fromMs: startedMs) else { continue }
            guard dateStr >= start && dateStr <= end else { continue }

            var existing = result[model] ?? ToolStat(model: model, toolCalls: 0, msgs: 0)
            existing = ToolStat(
                model: model,
                toolCalls: existing.toolCalls + tools,
                msgs: existing.msgs + 1
            )
            result[model] = existing
        }
        return result
    }

    // MARK: - Daily Tool Calls

    /// 区间内按日期聚合的 tool_call_count（仅 zcode 来源）。
    /// 返回 ["2026-07-20": 总工具调用数]。
    func dailyToolCalls(start: String, end: String) -> [String: Int] {
        guard let handle else { return [:] }
        var stmt: OpaquePointer?
        let sql = """
            SELECT started_at, tool_call_count
            FROM model_usage
            WHERE status = 'completed' AND started_at IS NOT NULL
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let startedMs = sqlite3_column_int64(stmt, 0)
            let tools = Int(sqlite3_column_int64(stmt, 1))
            guard tools > 0 else { continue }
            guard let dateStr = Self.localDateString(fromMs: startedMs) else { continue }
            guard dateStr >= start && dateStr <= end else { continue }
            result[dateStr, default: 0] += tools
        }
        return result
    }

    // MARK: - Reasoning Tokens (bonus)

    /// 按模型聚合 reasoning_tokens（区间内）。推理模型才 > 0。
    func reasoningTokensByModel(start: String, end: String) -> [String: Int] {
        guard let handle else { return [:] }
        var stmt: OpaquePointer?
        let sql = """
            SELECT model_id, started_at, reasoning_tokens
            FROM model_usage
            WHERE status = 'completed' AND started_at IS NOT NULL
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = String(cString: sqlite3_column_text(stmt, 0))
            let startedMs = sqlite3_column_int64(stmt, 1)
            let reasoning = Int(sqlite3_column_int64(stmt, 2))
            guard reasoning > 0 else { continue }
            guard let dateStr = Self.localDateString(fromMs: startedMs) else { continue }
            guard dateStr >= start && dateStr <= end else { continue }
            result[model, default: 0] += reasoning
        }
        return result
    }
}
