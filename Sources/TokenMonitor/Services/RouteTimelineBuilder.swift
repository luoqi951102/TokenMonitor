import Foundation

// MARK: - RouteTimelineBuilder
//
// 构造路由时间窗，用于双信号源回填 provider 的辅助信号。
// 移植自 token-count/ccusage/db.py 的 build_route_timeline / _extract_route_timeline_from_vclog
// / _extract_route_timeline_from_settings / _route_url_at。
//
// 双源融合：
//   1. VSCode Claude Code 扩展日志：每次启动打印 ANTHROPIC_BASE_URL=... + UTC timestamp。
//      覆盖 VSCode 跑过的会话；终端 Claude Code 切换抓不到。
//   2. ~/.claude/settings.json + 备份文件的 mtime：CCM 切供应商时 rewrite settings.json
//      触发 mtime 更新；备份文件（settings.json20260525 等）的 mtime 是冻结时刻。
//
// 融合后按 timestamp 排序，相邻同 baseURL 合并，每个点的 end = 下一个点的 start。
// 最后一个点的 end = now。落在两个点之间的 timestamp 用前一个点的 baseURL。

struct RouteWindow {
    let startUTC: Date       // 窗口开始（UTC）
    let endUTC: Date         // 窗口结束（UTC，半开区间）
    let baseURL: String
}

enum RouteTimelineBuilder {

    /// 构造路由时间窗列表，按时间排序。
    /// extraPoints: 额外人工切换点（测试用），与自动源合并排序。
    static func buildTimeline(extraPoints: [(Date, String)] = []) -> [RouteWindow] {
        var points: [(Date, String)] = []
        points += extractFromVSCodeLog()
        points += extractFromSettings()
        points += extraPoints
        points.sort { $0.0 < $1.0 }

        // 合并相邻同 baseURL（与 Python build_route_timeline 一致：
        // 相邻同 baseURL 则跳过——Python 注释说"更新时间戳到最新"但实际 else 分支是 pass，
        // 这里照 Python 实际行为：连续相同 baseURL 只保留第一个）
        var merged: [(Date, String)] = []
        for (dt, url) in points {
            if merged.isEmpty || merged.last!.1 != url {
                merged.append((dt, url))
            }
            // 否则 pass（Python else 分支是 pass）
        }

        guard !merged.isEmpty else { return [] }

        // 构造时间窗：[start_i, end_i) = [t_i, t_{i+1})，最后一个 end = now
        let now = Date()
        var windows: [RouteWindow] = []
        for i in 0..<merged.count {
            let start = merged[i].0
            let url = merged[i].1
            let end = (i + 1 < merged.count) ? merged[i + 1].0 : now
            windows.append(RouteWindow(startUTC: start, endUTC: end, baseURL: url))
        }
        return windows
    }

    /// 二分查找 timestamp 落在哪个路由窗，返回对应 baseURL。落不进任何窗返回空串。
    /// 移植自 Python _route_url_at：bisect_right(starts, ts) - 1。
    static func routeURLAt(ts: Date, windows: [RouteWindow]) -> String {
        if windows.isEmpty { return "" }

        // 二分：找最后一个 startUTC <= ts 的窗口
        var lo = 0, hi = windows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if windows[mid].startUTC <= ts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let idx = lo - 1
        if idx < 0 { return "" }
        let w = windows[idx]
        // 半开区间 [start, end)
        if w.startUTC <= ts && ts < w.endUTC {
            return w.baseURL
        }
        return ""
    }

    // MARK: - 源 1：VSCode Claude Code 扩展日志

    /// 扫 VSCode 扩展日志，提取 (timestamp, baseURL) 切换点。
    /// 日志路径：~/Library/Application Support/Code/logs/<日期>/window<N>/exthost/Anthropic.claude-code/Claude VSCode.log
    /// 每行匹配 UTC ISO timestamp + ANTHROPIC_BASE_URL=https://...
    private static func extractFromVSCodeLog() -> [(Date, String)] {
        let logDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Code/logs")
        guard FileManager.default.fileExists(atPath: logDir.path) else {
            return []
        }

        let urlPat = try? NSRegularExpression(
            pattern: "ANTHROPIC_BASE_URL=(https?://[^\\s,;\"]+)", options: []
        )
        let tsPat = try? NSRegularExpression(
            pattern: "(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d+)Z", options: []
        )
        guard let urlPat, let tsPat else { return [] }

        var points: [(Date, String)] = []

        // 遍历 logs/<日期>/window*/exthost/Anthropic.claude-code/Claude VSCode.log
        guard let dateDirs = try? FileManager.default.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let fm = FileManager.default
        for dateDir in dateDirs {
            // 每个日期目录下找 window*
            guard let windowDirs = try? fm.contentsOfDirectory(
                at: dateDir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for windowDir in windowDirs where windowDir.lastPathComponent.hasPrefix("window") {
                let exthost = windowDir.appendingPathComponent("exthost/Anthropic.claude-code/Claude VSCode.log")
                guard fm.fileExists(atPath: exthost.path) else { continue }
                guard let data = try? Data(contentsOf: exthost),
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                else { continue }

                for line in text.split(separator: "\n") {
                    let lineStr = String(line)
                    if !lineStr.contains("ANTHROPIC_BASE_URL=") { continue }

                    let lineRange = NSRange(lineStr.startIndex..<lineStr.endIndex, in: lineStr)
                    guard let urlMatch = urlPat.firstMatch(in: lineStr, options: [], range: lineRange),
                          let urlRange = Range(urlMatch.range(at: 1), in: lineStr)
                    else { continue }
                    var url = String(lineStr[urlRange])
                    // rstrip ,;"'
                    while let last = url.last, last == "," || last == ";" || last == "\"" || last == "'" {
                        url.removeLast()
                    }

                    guard let tsMatch = tsPat.firstMatch(in: lineStr, options: [], range: lineRange),
                          let tsRange = Range(tsMatch.range(at: 1), in: lineStr)
                    else { continue }
                    let tsStr = String(lineStr[tsRange]) + "Z"  // Python: m_ts.group(1) + "Z"
                    guard let dt = parseUTCISO(tsStr) else { continue }

                    points.append((dt, url))
                }
            }
        }

        points.sort { $0.0 < $1.0 }
        return points
    }

    // MARK: - 源 2：settings.json + 备份的 mtime

    /// 扫 ~/.claude/ 下所有 settings*.json 备份，提取 (mtime, baseURL) 切换点。
    /// Python 候选规则：当前 settings.json + 所有 settings.json<...>（非 settings.json 本身）+ settings.local.json
    private static func extractFromSettings() -> [(Date, String)] {
        let claudeDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            return []
        }

        var candidates: [URL] = []
        let main = claudeDir.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: main.path) {
            candidates.append(main)
        }
        // 备份文件 + settings.local.json
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: claudeDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for f in entries {
                let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDir { continue }
                let name = f.lastPathComponent
                // Python: name.startswith("settings.json") and name != "settings.json"
                if name.hasPrefix("settings.json") && name != "settings.json" {
                    candidates.append(f)
                }
                if name == "settings.local.json" {
                    candidates.append(f)
                }
            }
        }

        var points: [(Date, String)] = []
        for f in candidates {
            // 复用 ClaudeSettingsReader 的解析逻辑：读 env.ANTHROPIC_BASE_URL
            guard let url = readBaseURL(from: f), !url.isEmpty else { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            points.append((mtime, url))
        }
        points.sort { $0.0 < $1.0 }
        return points
    }

    // MARK: - Helpers

    /// 解析 "YYYY-MM-DDTHH:MM:SS.mmmZ" UTC ISO 字符串为 Date。
    /// 移植自 Python _parse_utc_iso：fromisoformat(把 Z 换成 +00:00)。
    private static func parseUTCISO(_ ts: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        if let d = f.date(from: ts) { return d }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        basic.timeZone = TimeZone(identifier: "UTC")
        return basic.date(from: ts)
    }

    /// 读指定 settings 文件的 env.ANTHROPIC_BASE_URL（复用 ClaudeSettingsReader 逻辑）。
    private static func readBaseURL(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = dict["env"] as? [String: Any],
              let u = env["ANTHROPIC_BASE_URL"] as? String
        else { return nil }
        return u
    }
}
