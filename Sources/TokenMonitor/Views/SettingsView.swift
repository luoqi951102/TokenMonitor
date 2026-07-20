import SwiftUI
import AppKit

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                syncSection
                databaseSection
                defaultsSection
                aboutSection
            }
            .padding(20)
        }
        .background(Theme.windowBackground(for: .dark))
        .frame(width: 420, height: 520)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(Theme.brand)
            Text("设置")
                .font(.title2.weight(.semibold))
            Spacer()
        }
    }

    // MARK: - Sync

    @ViewBuilder
    private var syncSection: some View {
        card(title: "数据同步", icon: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                Text("App 在沙盒中运行，无法直接调用 cc-use。请在终端手动执行同步，或安装 launchd 定时任务自动同步。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("在终端运行 sync") {
                        viewModel.syncRunner.openInTerminal()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)

                    Button("刷新视图") {
                        viewModel.openDB()
                        viewModel.refresh()
                        viewModel.pushWidgetSnapshot()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }

                Divider().opacity(0.3)

                HStack {
                    Text("刷新间隔")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Picker("", selection: $viewModel.syncRunner.intervalMinutes) {
                        Text("5 分钟").tag(5)
                        Text("10 分钟").tag(10)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if let last = viewModel.syncRunner.lastSyncAt {
                    Text("上次视图刷新：\(formatTime(last))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.3)

                HStack {
                    Button("显示桌面小窗") {
                        FloatingWidgetWindow.shared.show(viewModel: viewModel)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)

                    Button("隐藏桌面小窗") {
                        FloatingWidgetWindow.shared.hide()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Database

    @ViewBuilder
    private var databaseSection: some View {
        card(title: "数据源授权", icon: "internaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                // 授权提示
                Text("App 在沙盒中运行，需要授权访问以下文件。授权一次永久生效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // ccusage.db
                bookmarkRow(
                    label: "ccusage.db",
                    recommendedPath: UsageDBPath.ccusageDefault,
                    key: .ccusageDB,
                    prompt: "选择 ccusage.db",
                    allowedTypes: ["sqlite", "db"]
                )

                // ZCode db
                bookmarkRow(
                    label: "ZCode db.sqlite",
                    recommendedPath: UsageDBPath.zcodeDefault,
                    key: .zcodeDB,
                    prompt: "选择 db.sqlite",
                    allowedTypes: ["sqlite", "db"]
                )

                if let start = viewModel.dataSpan.start, let end = viewModel.dataSpan.end {
                    Divider().opacity(0.3)
                    row(label: "数据范围", value: "\(start) ~ \(end)")
                    row(label: "记录数", value: "\(viewModel.totalMsgs + Int(viewModel.models.reduce(0) { $0 + $1.msgCount }))")
                }
            }
        }
    }

    /// 单行 bookmark 授权控件
    private func bookmarkRow(
        label: String,
        recommendedPath: String,
        key: BookmarkStore.Key,
        prompt: String,
        allowedTypes: [String]?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                Spacer()
                if BookmarkStore.shared.has(key) {
                    Label("已授权", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Label("未授权", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 6) {
                Text("建议路径：\(recommendedPath)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            HStack {
                Button("选择文件…") {
                    pickFile(label: label, key: key, prompt: prompt, allowedTypes: allowedTypes)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .controlSize(.small)
                .font(.caption)

                if BookmarkStore.shared.has(key) {
                    Button("清除") { BookmarkStore.shared.clear(key) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.caption)
                }
                Spacer()
            }
        }
    }

    private func pickFile(label: String, key: BookmarkStore.Key, prompt: String, allowedTypes: [String]?) {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.prompt = "授权"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let types = allowedTypes {
            panel.allowedFileTypes = types
        }
        // 默认打开推荐目录
        let home = NSHomeDirectory()
        let defaultPath: String
        switch key {
        case .ccusageDB: defaultPath = "\(home)/.claude"
        case .zcodeDB: defaultPath = "\(home)/.zcode/cli/db"
        case .ccUsageExe: defaultPath = "\(home)/.local/bin"
        }
        panel.directoryURL = URL(fileURLWithPath: defaultPath)

        if panel.runModal() == .OK, let url = panel.url {
                if BookmarkStore.shared.save(url, for: key) {
                    // 触发 viewModel 重新打开 DB + 刷新 + 推送 widget
                    viewModel.openDB()
                    viewModel.refresh()
                    viewModel.pushWidgetSnapshot()
                }
        }
    }

    private func revealDB() {
        if let url = BookmarkStore.shared.resolve(.ccusageDB) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            BookmarkStore.shared.release(url)
        } else {
            let url = URL(fileURLWithPath: UsageDBPath.ccusageDefault)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Defaults

    @ViewBuilder
    private var defaultsSection: some View {
        card(title: "默认视图", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("默认范围", selection: $viewModel.range) {
                    ForEach(UsageRange.allCases, id: \.self) { r in
                        Text(r.displayName).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                Picker("默认来源", selection: $viewModel.source) {
                    Text("全部").tag("all")
                    Text("Claude").tag("claude")
                    Text("ZCode").tag("zcode")
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        card(title: "关于", icon: "info.circle") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Token Monitor")
                    .font(.caption.weight(.semibold))
                Text("本地 token 用量监控小组件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("数据由 cc-usage (token-count) 同步")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private func card<C: View>(title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(Theme.brand)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
