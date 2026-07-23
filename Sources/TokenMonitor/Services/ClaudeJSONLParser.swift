import Foundation

// MARK: - ClaudeJSONLParser
//
// 解析 Claude Code 会话 JSONL 文件，提取 token 用量记录。
// 移植自 token-count/ccusage/parser.py 的 parse_file() + iter_jsonl_files()。
//
// 每个 ~/.claude/projects/<project>/<sessionId>.jsonl 文件是一个会话，
// 其中 type=='assistant' 的行包含 message.usage 字段，是我们的数据源。
//
// 容错约定（与 Python 严格对齐，逐行跳过不抛错）：
//   - 空行 / 坏 JSON / 非 dict / type≠assistant / 缺 message / 缺 usage / usage 空 dict
//   - model ∈ {"<synthetic>", "", nil}
//   - 缺 timestamp
//   - 顶层字段非字符串当空串；token nil 当 0
//
// timestamp 原样保留 ISO UTC 字符串（如 "2026-05-29T09:05:31.140Z"），
// 禁转 Date 再格式化——provider 快照按 timestamp 精确匹配的关键。

struct ClaudeUsageRecord {
    /// ISO UTC，原文照存，e.g. 2026-05-29T09:05:31.140Z
    let timestamp: String
    let model: String
    let inputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let outputTokens: Int
    let sessionID: String
    let cwd: String
    let project: String
    let sourceFile: String
}

enum ClaudeJSONLParser {

    /// 跳过这些非真实模型（与 Python _IGNORED_MODELS 对齐）
    private static let ignoredModels: Set<String> = ["<synthetic>", ""]

    /// 遍历 projects 目录下所有 *.jsonl 文件，yield (filepath, project_name)。
    /// 与 Python iter_jsonl_files() 一致：projects_dir 不存在则空序列；
    /// 子目录 sorted 遍历，每个子目录内 *.jsonl sorted 遍历。
    static func iterJSONLFiles(
        projectsDir: URL,
        securityScoped: Bool
    ) -> [(file: URL, project: String)] {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return []
        }

        // 获取 directoryContents，若 sandbox 下读不了返回空
        let subdirURLs: [URL]
        if securityScoped, let raw = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            subdirURLs = raw
        } else if let raw = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            subdirURLs = raw
        } else {
            return []
        }

        // 只取子目录，排序
        let projectDirs = subdirURLs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var result: [(file: URL, project: String)] = []
        for projectDir in projectDirs {
            let projectName = projectDir.lastPathComponent
            // 子目录内 *.jsonl sorted 遍历
            if let jsonlFiles = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                let sorted = jsonlFiles
                    .filter { $0.pathExtension == "jsonl" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for f in sorted {
                    result.append((file: f, project: projectName))
                }
            }
        }
        return result
    }

    /// 解析单个 JSONL 会话文件，流式逐行读。
    /// 与 Python parse_file() 完全对齐：整文件读完按 \n 切行，每行单独 JSONSerialization，
    /// 容错跳过。文件打不开 / 读失败返回空数组（不抛错，与 Python 的 except OSError 一致）。
    ///
    /// 用整文件 Data 读取而非 FileHandle.readLine 异步序列：JSONL 会话文件通常几 MB 级，
    /// 一次性读更简单稳定，跨 macOS 版本兼容，不引入 async 复杂度。
    static func parseFile(
        at fileURL: URL,
        project: String
    ) -> [ClaudeUsageRecord] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        var records: [ClaudeUsageRecord] = []
        let filePath = fileURL.path

        // 按 \n 切行（同时兼容 \r\n：行尾 trim 掉所有 whitespace）
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            // trim 行首尾空白（处理 \r\n 和空行）
            var bytes = Array(line)
            // 去尾部 \r / space
            while let last = bytes.last, last == 0x0D || last == 0x20 || last == 0x09 {
                bytes.removeLast()
            }
            // 去首部 space / tab
            while let first = bytes.first, first == 0x20 || first == 0x09 {
                bytes.removeFirst()
            }
            if bytes.isEmpty { continue }

            guard let lineData = Data(bytes) as Data?,
                  lineData.count > 0,
                  let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }
            guard (parsed["type"] as? String) == "assistant" else { continue }
            guard let msg = parsed["message"] as? [String: Any] else { continue }
            guard let usage = msg["usage"] as? [String: Any], !usage.isEmpty else { continue }

            let model = msg["model"] as? String ?? ""
            if ignoredModels.contains(model) { continue }

            guard let ts = parsed["timestamp"] as? String, !ts.isEmpty else { continue }

            records.append(
                ClaudeUsageRecord(
                    timestamp: ts,
                    model: model,
                    inputTokens: intValue(usage["input_tokens"]),
                    cacheCreationInputTokens: intValue(usage["cache_creation_input_tokens"]),
                    cacheReadInputTokens: intValue(usage["cache_read_input_tokens"]),
                    outputTokens: intValue(usage["output_tokens"]),
                    sessionID: stringValue(parsed["sessionId"]),
                    cwd: stringValue(parsed["cwd"]),
                    project: project,
                    sourceFile: filePath
                )
            )
        }

        return records
    }

    /// 返回文件的 (mtime, size)，用于增量同步水位。读 stat 失败返回 nil。
    static func fileSignature(at fileURL: URL) -> (mtime: Double, size: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return nil
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? Int) ?? 0
        return (mtime, size)
    }

    // MARK: - Private: 值提取（容错）

    /// Python int(usage.get(k) or 0) 的等价：nil → 0，非数字 → 0，否则 Int。
    private static func intValue(_ any: Any?) -> Int {
        guard let any else { return 0 }
        if let n = any as? Int { return n }
        if let n = any as? Int64 { return Int(n) }
        if let n = any as? Double { return Int(n) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    /// str(d.get(k) or "")：nil → ""，非字符串转字符串。
    private static func stringValue(_ any: Any?) -> String {
        guard let any else { return "" }
        if let s = any as? String { return s }
        return String(describing: any)
    }
}
