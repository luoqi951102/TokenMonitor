# Changelog

本项目从 0.2.0 起开始记录变更。版本号遵循 [SemVer](https://semver.org/)。

## 0.2.0 — 2026-07-23

### ✅ Python `cc-usage sync` 全套私有化进 Swift

生成的 DMG 装到干净 Mac 上即可独立运行，**不再依赖 Python `cc-usage`**。新增 ~1100 行 Swift，经与 Python 基线双跑对账零差异（来源行数 / 每 model token 总量 / ZCode 水位线 / ext_id 去重 / Claude 17 维度五维度全一致）。

#### 新增

- **`Services/CCUsageDB.swift`** — 可写 `ccusage.db` 句柄，`SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE` 打开，启动即幂等建表 + 旧库迁移补 `source/ext_id/provider` 列 + `PRAGMA WAL`
- **`Services/DBMigration.swift`** — 与 Python `db.py` SCHEMA 严格对齐的建表/索引 SQL（18 列含 `id`）+ 幂等 `idempotentMigrate(on:)`
- **`Services/ClaudeJSONLParser.swift`** — 移植 `parser.py`，整文件按 `\n` 切行逐行 `JSONSerialization` 解析，行级容错（非 dict / type≠assistant / 缺 usage全跳过）
- **`Services/ClaudeSync.swift`** — 移植 `db.py sync()`：files (mtime,size) 水位表、provider 快照回填（避免 append 后整盘刷写供应商）、going-forward `ANTHROPIC_BASE_URL` 打标
- **`Services/ClaudeSettingsReader.swift`** — 移植 `_read_claude_base_url()`，sandbox 下走 `Key.claudeSettings` bookmark 回退默认路径
- **`Services/ZCodeSync.swift`** — 移植 `sync_zcode()`：`completed_at` 水位线（`meta.zcode_last_completed_at`）、分桶用 `started_at`、`INSERT OR IGNORE` 靠 `(source, ext_id)` 唯一索引幂等
- **`Services/SandboxAuthorizer.swift`** — 集中三处 NSOpenPanel 授权（projects 目录 / ZCode db / ccusage.db）
- **`Services/ProviderClassifier.swift`** — 移植 `_classify_provider_from_msgid` + `_MSGID_PATTERNS`（4 条 NSRegularExpression + UUID 按 model 分流）
- **`Services/RouteTimelineBuilder.swift`** — 移植 `build_route_timeline` 双源融合（VSCode 扩展日志 + settings.json mtime → 时间窗，二分查找）
- **`Services/Backfiller.swift`** — 集中三运维命令：`backfillProvider` 单信号源 / `reconcileProviders` 双信号决策矩阵（strict/msgid/route 五分统计）/ `dedupeClaudeRows` 临时表 + `MIN(rowid)` 去重。全部支持 `dryRun`

#### 变更

- **`Services/BookmarkStore.swift`** — `Key` 枚举新增 `claudeProjectsDir`、`claudeSettings`，`clearAll` 同步更新
- **`Services/SyncRunner.swift`** — `syncNow()` 在三授权齐全时跑 Swift 端真同步（`ClaudeSync` + `ZCodeSync`），否则保留旧 fallback；新增 `runSwiftSync()` 全程长持有 security-scoped URL；`@Published lastStats: SyncReport`
- **`ViewModels/DashboardViewModel.swift`** — `manualSync()` 去 mtime-gated 直接 `openDB()` 重建只读句柄（Swift sync 必改库）
- **`Views/SettingsView.swift`** — 新增「历史数据修复」卡片：三命令各带 dry-run 预览 + 执行按钮 + 结果摘要；「数据源授权」卡片补 projects 目录 / settings.json 两处授权行；`pickFile` 对 `claudeProjectsDir` 切目录选择模式；高度 520 → 660

### 旧版

- **0.1.0** — 初版菜单栏 + 浮窗 + Widget 三档、Apple 风格重设计（W1-W4）、provider 识别路由、tool_calls 间歇 0 修复、历史重复行去重（6.429B → 3.153B）
