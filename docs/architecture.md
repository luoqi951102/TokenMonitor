# Architecture

二开自 [DeepSeekMonitor](https://github.com/luoqi951102/DeepSeekMonitor)（Swift macOS 菜单栏 + WidgetKit 外壳），数据管线来自 [token-count / cc-usage](https://github.com/luoqi951102/token-count)（Python CLI）。

## 与原项目的差异

| 维度 | DeepSeekMonitor | Token Monitor |
|---|---|---|
| 数据来源 | DeepSeek 官方 API + CSV 导入 + WKWebView 抓取 | 本地 `ccusage.db` + ZCode db（只读） |
| 费用/余额 | ✅ 有 | ❌ 无 |
| 模型 | 硬编码 deepseek-chat / deepseek-reasoner | **模型无关**（日志里是什么就显示什么） |
| 工具调用 | ❌ 不追踪 | ✅ 从 ZCode db 补齐 `tool_call_count` |
| 时序数据 | 7 天回溯 | 任意 range（今日/本周/本月/全部） |
| 来源筛选 | ❌ 单一账号 | ✅ all / claude / zcode |

## 模块

### `Sources/TokenMonitor/`

| 文件 | 职责 |
|---|---|
| `App.swift` | `@main`，注册 sleep/wake 监听，处理 `tokenmonitor://` 深链 |
| `MenuBarManager.swift` | NSStatusItem + FloatingPanel + 右键菜单 + hover 自动关闭 |
| `Models.swift` | `ModelUsage` / `DailyTotal` / `WidgetSnapshot` / `UsageRange` / `UsageSource` |
| `Theme.swift` | 中性 Indigo 品牌色 `#5B6CFF` + token 构成配色 + 模型色板 |
| `Services/UsageDB.swift` | 只读打开 `ccusage.db`（SQLite3 C API，两级降级 immutable=1 → mode=ro） |
| `Services/ZCodeUsageDB.swift` | 只读打开 ZCode `model_usage` 表，补齐 `tool_call_count` / `reasoning_tokens` |
| `Services/Aggregator.swift` | 移植自 `ccusage/aggregate.py` 的 SQL 聚合（by_model / daily / hourly / streak / wow / source_breakdown） |
| `Services/SyncRunner.swift` | 异步 spawn `cc-usage sync`，定时器 + 手动触发 + PATH 自动探测 |
| `Services/WidgetStore.swift` | App Group snapshot 写入 + `WidgetCenter.reloadTimelines` |
| `ViewModels/DashboardViewModel.swift` | `@MainActor ObservableObject`，range/source 切换时重新聚合 |
| `Views/ContentView.swift` | 三 tab（总览 / 模型 / 工具）+ range/source 筛选条 |
| `Views/ModelComparisonView.swift` | 全模型表 + token 构成堆叠柱 |
| `Views/ToolCallView.swift` | 工具调用排行 + 比率 + 日趋势 |
| `Views/SettingsView.swift` / `SettingsWindowController.swift` | cc-usage 路径 / 刷新间隔 / 数据源 / 默认 range/source |

### `Sources/WidgetSupport/`

| 文件 | 职责 |
|---|---|
| `DeepSeekWidget.swift` | `@main WidgetBundle`（文件名保留以避免改 Package） |
| `TimelineProvider.swift` | 从 App Group 读 `WidgetSnapshot`，1 小时 fallback |
| `WidgetViews.swift` | Small / Medium / Large 三档视图 |

## 数据模型

### `ModelUsage`（核心，模型无关）

```swift
struct ModelUsage {
    let model: String                  // "glm-5.2" / "claude-sonnet-4-5" …
    let source: String                 // "claude" | "zcode"
    let inputTokens: Int
    let cacheCreationTokens: Int       // 缓存写入
    let cacheReadTokens: Int           // 缓存命中
    let outputTokens: Int
    let totalContextTokens: Int        // = input + cache_creation + cache_read（不含 output）
    let msgCount: Int
    let toolCallCount: Int             // 仅 zcode 来源 > 0

    var totalTokens: Int { totalContextTokens + outputTokens }
    var toolCallsPerMsg: Double { ... }
}
```

### `WidgetSnapshot`

```swift
struct WidgetSnapshot {
    let generatedAt: Date
    let range: String                  // today | week | month | all
    let source: String                 // all | claude | zcode
    let totalTokens, totalToolCalls, totalMsgs: Int
    let topModels: [ModelUsage]        // top 5
    let daily: [DailyTotal]            // 最近 14 天
    let lastSyncAt: Date?
}
```

## 时区

所有日期分桶固定 Asia/Shanghai（与 ccusage 写入时分桶一致），避免 UTC 偏移导致跨日。`Aggregator.shanghaiCalendar()` 设置 `firstWeekday = 2`（周一为周首）。

## 源过滤技巧

复用 token-count 的 SQL 小技巧，让 `source = 'all'` 时不过滤：

```sql
WHERE (source = ? OR ? = 'all')
-- 双绑定：参数 = [source, source]
```

## cc-usage 的局限

ccusage.db 不存 `tool_call_count`，所以 Swift 端绕开它直接读 ZCode 原生 db.sqlite：

```swift
let zcodeStats = zcodeDB.toolCallsByModel(start:..., end:...)
// 按 (model, started_at→local_date) 聚合
// 关联回 ccusage 中 source=zcode 的行
```

## App Group 与 bundle ID

- App bundle: `com.luoqi.tokenmonitor`
- Widget bundle: `com.luoqi.tokenmonitor.widget`
- App Group: `N5YV5FV235.group.com.luoqi.tokenmonitor`（沿用 DeepSeekMonitor 的 Team ID）
- URL Scheme: `tokenmonitor://refresh` / `tokenmonitor://settings`

## 打包路径

`build.sh` 流程：
1. `increment_build` — 自增 plist 的 `CFBundleVersion`
2. `kill_running_app` — 终止旧实例
3. `cleanup_project_system_state` — 清理 LaunchServices + WidgetKit Chrono 缓存
4. `build_release_xcode`（有 .xcodeproj）或 `build_release_universal`（fallback，无 widget）
5. `sign_bundle` — codesign（ad-hoc 或 Apple Development）
6. `create_dmg` — 打 DMG

> SwiftPM 单独编译（`swift build`）不带 entitlements 沙盒，可直接读 `~/.claude`；打包成 .app 后需要 entitlements 里声明 `com.apple.security.files.user-selected.read-only` + 显式 user-selected 文件访问权限（macOS 沙盒默认禁止读 `~/.claude`，可能需要改成非 sandbox 或在 Settings 里让用户通过 NSOpenPanel 授权）。
