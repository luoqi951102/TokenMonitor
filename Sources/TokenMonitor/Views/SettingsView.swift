import SwiftUI
import AppKit

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme

    // 历史修复卡片状态：三命令各自的 dry-run 结果 + 执行中状态
    @State private var dedupeReport: Backfiller.DedupeReport?
    @State private var backfillReport: BackfillReport?
    @State private var reconcileReport: Backfiller.ReconcileReport?
    @State private var isRunningFix = false
    @State private var fixError: String?
    // dry-run vs 实际执行模式切换（每命令独立）
    @State private var dedupeExecuted = false
    @State private var backfillExecuted = false
    @State private var reconcileExecuted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                syncSection
                loginItemSection
                databaseSection
                historyFixSection
                defaultsSection
                aboutSection
            }
            .padding(20)
        }
        .background(Theme.windowBackground(for: .dark))
        .frame(width: 420, height: 660)
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

                Divider().opacity(0.3)
                Text("Swift 端自同步需要以下额外授权（目录扫描 + 配置读取）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // Claude projects 目录（Swift sync 扫 JSONL 必需）
                bookmarkRow(
                    label: "Claude projects 目录",
                    recommendedPath: NSHomeDirectory() + "/.claude/projects",
                    key: .claudeProjectsDir,
                    prompt: "选择 projects 目录",
                    allowedTypes: nil
                )

                // Claude settings.json（读 baseURL 打标用）
                bookmarkRow(
                    label: "Claude settings.json",
                    recommendedPath: NSHomeDirectory() + "/.claude/settings.json",
                    key: .claudeSettings,
                    prompt: "选择 settings.json",
                    allowedTypes: ["json"]
                )

                if let start = viewModel.dataSpan.start, let end = viewModel.dataSpan.end {
                    Divider().opacity(0.3)
                    row(label: "数据范围", value: "\(start) ~ \(end)")
                    row(label: "记录数", value: "\(viewModel.totalMsgs + Int(viewModel.models.reduce(0) { $0 + $1.msgCount }))")
                }
            }
        }
    }

    // MARK: - History Fix（三运维命令 Swift 化）

    @ViewBuilder
    private var historyFixSection: some View {
        card(title: "历史数据修复", icon: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 14) {
                Text("对历史数据做一次性修复。先 dry-run 预览影响，确认无误后再实际执行。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // 1) 去重
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("① 去掉 Claude 重复行").font(.caption.weight(.medium))
                        Spacer()
                        Button("dry-run") { runDedupe(dryRun: true) }
                            .buttonStyle(.bordered).controlSize(.small).font(.caption)
                            .disabled(isRunningFix)
                        if dedupeReport != nil, !dedupeExecuted {
                            Button("执行") { runDedupe(dryRun: false); dedupeExecuted = true }
                                .buttonStyle(.borderedProminent).controlSize(.small).font(.caption)
                                .tint(Theme.brand).disabled(isRunningFix)
                        }
                    }
                    if let r = dedupeReport {
                        Text(dedupeSummary(r))
                            .font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // 2) backfill provider
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("② msgid 指纹回填空 provider").font(.caption.weight(.medium))
                        Spacer()
                        Button("dry-run") { runBackfill(dryRun: true) }
                            .buttonStyle(.bordered).controlSize(.small).font(.caption)
                            .disabled(isRunningFix)
                        if backfillReport != nil, !backfillExecuted {
                            Button("执行") { runBackfill(dryRun: false); backfillExecuted = true }
                                .buttonStyle(.borderedProminent).controlSize(.small).font(.caption)
                                .tint(Theme.brand).disabled(isRunningFix)
                        }
                    }
                    if let r = backfillReport {
                        Text(backfillSummary(r))
                            .font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // 3) reconcile
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("③ 双信号源对账（msgid + 路由窗）").font(.caption.weight(.medium))
                        Spacer()
                        Button("dry-run") { runReconcile(dryRun: true) }
                            .buttonStyle(.bordered).controlSize(.small).font(.caption)
                            .disabled(isRunningFix)
                        if reconcileReport != nil, !reconcileExecuted {
                            Button("执行") { runReconcile(dryRun: false); reconcileExecuted = true }
                                .buttonStyle(.borderedProminent).controlSize(.small).font(.caption)
                                .tint(Theme.brand).disabled(isRunningFix)
                        }
                    }
                    if let r = reconcileReport {
                        Text(reconcileSummary(r))
                            .font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if isRunningFix {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("扫描中…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let err = fixError {
                    Text("⚠️ \(err)").font(.caption).foregroundStyle(.red)
                }
                Text("注：provider 字段只对历史空行回填，已带标签的不动；路由窗时间戳来自 VSCode 扩展日志 + settings.json mtime。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func dedupeSummary(_ r: Backfiller.DedupeReport) -> String {
        let dupDesc = r.dupGroupsByCount.filter { $0.n > 1 }
            .map { "n=\($0.n)×\($0.groups)" }.joined(separator: " ")
        let tokenB = Double(r.beforeTotalTokens) / 1e9
        let tokenA = Double(r.afterTotalTokens) / 1e9
        if r.deletedRows == 0 {
            return "✓ 无重复行（\(r.beforeRows) 行全部唯一）。无需操作"
        }
        return "重复分布: \(dupDesc) | 待删 \(r.deletedRows) 行 | "
            + "token \(tokenB)B → \(tokenA)B"
            + (r.dryRun ? " 〔dry-run〕" : " 〔已执行〕")
    }

    private func backfillSummary(_ r: BackfillReport) -> String {
        if r.matched == 0 {
            return "✓ 无可回填（JSONL 未扫到 msgid 命中）"
        }
        let topMatch = r.writeDist.prefix(3)
            .map { "\($0.model)→\($0.url) ×\($0.count)" }.joined(separator: " | ")
        return "扫描 \(r.scanned) | 命中 \(r.matched) | 未匹配 \(r.unmatched)"
            + (r.dryRun ? " 〔dry-run〕" : " | 已回填 \(r.updated) 行")
            + "\n分布: \(topMatch)"
    }

    private func reconcileSummary(_ r: Backfiller.ReconcileReport) -> String {
        return "路由窗 \(r.routeWindows.count) 个 | scanned \(r.scanned)\n"
            + "verified \(r.verified) · msgid_only \(r.msgidOnly) · route_only \(r.routeOnly)\n"
            + "conflict \(r.conflict) (prefer=\(r.prefer.rawValue) 写 \(r.conflictWritten)) · unmatched \(r.unmatched)"
            + (r.dryRun ? " 〔dry-run〕" : " | 已更新 \(r.updated) 行")
    }

    // MARK: - History Fix Actions

    private func runDedupe(dryRun: Bool) {
        guard let db = openWritableDB() else { return }
        isRunningFix = true
        // dedupe 不需要扫 JSONL，直接同步执行（SQLite 查询很快）
        let r = Backfiller.dedupeClaudeRows(db: db, dryRun: dryRun)
        withAnimation(.easeOut(duration: 0.2)) { dedupeReport = r }
        isRunningFix = false
        if !dryRun { viewModel.openDB(); viewModel.refresh() }
    }

    private func runBackfill(dryRun: Bool) {
        guard let (db, projectsURL) = openWritableDBAndProjects() else { return }
        isRunningFix = true
        // 扫 JSONL 在后台，避免阻塞 UI
        Task {
            // 在后台线程跑扫描 + 写入
            let r = await Task.detached(priority: .utility) { () -> BackfillReport in
                defer { BookmarkStore.shared.release(projectsURL) }
                return Backfiller.backfillProvider(
                    db: db, projectsDirURL: projectsURL, dryRun: dryRun
                )
            }.value
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { backfillReport = r }
                isRunningFix = false
                if !dryRun { viewModel.openDB(); viewModel.refresh() }
            }
        }
    }

    private func runReconcile(dryRun: Bool) {
        guard let (db, projectsURL) = openWritableDBAndProjects() else { return }
        isRunningFix = true
        Task {
            let r = await Task.detached(priority: .utility) { () -> Backfiller.ReconcileReport in
                defer { BookmarkStore.shared.release(projectsURL) }
                return Backfiller.reconcileProviders(
                    db: db, projectsDirURL: projectsURL, dryRun: dryRun
                )
            }.value
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { reconcileReport = r }
                isRunningFix = false
                if !dryRun { viewModel.openDB(); viewModel.refresh() }
            }
        }
    }

    /// 打开可写 ccusage.db。失败时设 fixError 并返回 nil。
    private func openWritableDB() -> CCUsageDB? {
        guard let db = CCUsageDB(path: UsageDBPath.ccusageDefault) else {
            fixError = "无法打开 ccusage.db（请先在上方授权）"
            return nil
        }
        return db
    }

    /// 打开可写 db + 解开 projects 目录的 security-scoped URL（同步方负责用完 release）。
    /// 成功返回 (db, url)。db 在闭包内用、url 需调用方 release。
    private func openWritableDBAndProjects() -> (CCUsageDB, URL)? {
        guard let db = openWritableDB() else { return nil }
        guard let projectsURL = BookmarkStore.shared.resolve(.claudeProjectsDir) else {
            fixError = "Claude projects 目录未授权（请在上方授权后重试）"
            return nil
        }
        return (db, projectsURL)
    }

    /// 单行 bookmark 授权控件
    private func bookmarkRow(
        label: String,
        recommendedPath: String,        key: BookmarkStore.Key,
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
        // claudeProjectsDir 是目录授权，其余是单文件授权
        if key == .claudeProjectsDir {
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
        } else {
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            if let types = allowedTypes {
                panel.allowedFileTypes = types
            }
        }
        // 默认打开推荐目录
        let home = NSHomeDirectory()
        let defaultPath: String
        switch key {
        case .ccusageDB: defaultPath = "\(home)/.claude"
        case .zcodeDB: defaultPath = "\(home)/.zcode/cli/db"
        case .ccUsageExe: defaultPath = "\(home)/.local/bin"
        case .claudeProjectsDir: defaultPath = "\(home)/.claude/projects"
        case .claudeSettings: defaultPath = "\(home)/.claude"
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

    // MARK: - Login Item（开机自启动）

    @StateObject private var loginItem = LoginItemStore.shared

    @ViewBuilder
    private var loginItemSection: some View {
        card(title: "开机自启动", icon: "power") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("登录后自动启动 Token Monitor")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { newValue in
                            if newValue {
                                loginItem.enable()
                            } else {
                                loginItem.disable()
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(Theme.brand)
                }

                Text("启用后会在「系统设置 → 通用 → 登录项与扩展」里出现 Token Monitor，可随时手动开关。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("打开系统设置") {
                        loginItem.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                    Spacer()
                }

                if let err = loginItem.errorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
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
                    .font(Theme.Typography.title)
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(Theme.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
