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
        card(title: "同步", icon: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("cc-usage 可执行文件")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if viewModel.syncRunner.isAvailable {
                        Label("可用", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Label("未找到", systemImage: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                TextField("cc-usage 路径", text: $viewModel.syncRunner.ccUsageOverride)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                if let path = viewModel.syncRunner.resolvedCCUsagePath {
                    Text("当前使用：\(path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Picker("刷新间隔", selection: $viewModel.syncRunner.intervalMinutes) {
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30)
                    Text("60 分钟").tag(60)
                }
                .pickerStyle(.menu)

                HStack {
                    Button("立即同步") {
                        Task { await viewModel.manualSync() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .disabled(viewModel.syncRunner.isSyncing || !viewModel.syncRunner.isAvailable)

                    if viewModel.syncRunner.isSyncing {
                        ProgressView().scaleEffect(0.7)
                        Text("同步中…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let err = viewModel.syncRunner.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
        }
    }

    // MARK: - Database

    @ViewBuilder
    private var databaseSection: some View {
        card(title: "数据源", icon: "internaldrive") {
            VStack(alignment: .leading, spacing: 8) {
                row(label: "ccusage.db", value: UsageDBPath.ccusageDefault)
                row(label: "ZCode db", value: UsageDBPath.zcodeDefault)
                if let start = viewModel.dataSpan.start, let end = viewModel.dataSpan.end {
                    row(label: "数据范围", value: "\(start) ~ \(end)")
                }
                HStack {
                    Button("打开 ccusage.db 所在目录") { revealDB() }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    Spacer()
                }
            }
        }
    }

    private func revealDB() {
        let url = URL(fileURLWithPath: UsageDBPath.ccusageDefault)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
}
