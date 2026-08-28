import Foundation

/// 简易诊断 Logger：在 sandbox 容器 Documents/log.txt 追加诊断行。
/// 专门为「装了新包但 UI 显示 0」这类远程故障设计 — 用户崩溃、报错、
/// 在 Settings 里粘诊断文件或者直接 cat ~/Library/Containers/com.luoqi.tokenmonitor/Data/Documents/log.txt
/// 都能拿到关键现场。
///
/// 故意极简：无需配置、无副依赖、靠 append 写容器 Documents, sandbox 默认允许容器内自写。
enum DiagnosticLogger {

    /// 容器 Documents 目录下的 log 路径（sandbox 下唯一可写、用户易找的位置）。
    static var logPath: String {
        // NSHomeDirectory() 在 sandbox 下返回容器路径
        return NSHomeDirectory() + "/Documents/log.txt"
    }

    /// 追加一行诊断，带时间戳 prefix。
    /// 不会抛错；写入失败（目录不存在等）就静默吞。
    static func log(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] " + msg + "\n"
        let path = logPath
        // 确保 Documents 目录存在
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 清空日志文件。用于设置页「清空诊断」按钮。
    static func clear() {
        try? FileManager.default.removeItem(atPath: logPath)
    }

    /// 简短摘要：日志文件存在则返回前 N 行（默认 200），不存在返回 "(空)"
    static func summary(maxLines: Int = 200) -> String {
        guard let txt = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return "(空)"
        }
        let lines = txt.split(separator: "\n")
        if lines.count > maxLines {
            return lines.suffix(maxLines).joined(separator: "\n")
        }
        return txt
    }
}
