# Token Monitor

一个 macOS 菜单栏 + WidgetKit 小组件，监控本地 LLM token 用量、模型对比与工具调用。**不含费用、不含余额、不上传任何数据**。

数据来源：本地 Swift 端自同步（0.2.0 起私有化原生实现，扫 Claude Code + ZCode 本地日志到 `~/.claude/ccusage.db`）；Python [`cc-usage`](https://github.com/luoqi951102/token-count) 仅作可选的命令行管理工具保留。

## 特性

- 📊 **菜单栏面板**：range（今日 / 本周 / 本月 / 全部）× source（全部 / Claude / ZCode）双维度筛选
- 🤖 **模型对比**：input / cache_write / cache_read / output / total / msgs / tool_calls 表 + 堆叠构成图，**模型无关**（日志里是什么模型就显示什么）
- 🔧 **工具调用**：哪个模型最爱调工具、调用密度、日趋势（仅 ZCode 来源有数据）
- 🎛 **WidgetKit 三档**：Small / Medium / Large 桌面小组件
- 🔁 **自同步**：0.2.0 起 Swift 原生扫 JSONL + ZCode SQLite 增量写库，无需 Python 依赖
- 🛠 **历史修复**：设置页集成去重 / msgid 指纹回填 / 双信号源对账三命令，全部 dry-run 预览
- 🚫 **不涉及费用**：与 DeepSeekMonitor 的核心差异

## 截图

| 菜单栏面板 | 模型对比 | 工具调用 | Widget |
|---|---|---|---|
| (待补) | (待补) | (待补) | (待补) |

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                       TokenMonitor (主 App)                 │
│                                                             │
│  ┌───────────────┐    ┌───────────────────────┐             │
│  │  SyncRunner   │───▶│  Swift 端自同步        │             │
│  │ (定时 + 手动) │    │  ClaudeSync + ZCodeSync│             │
│  └───────────────┘    └───────────┬───────────┘             │
│         ▼                         │                         │
│  ┌───────────────┐                ▼                         │
│  │  Aggregator   │◀── ~/.claude/ccusage.db  (可写)          │
│  │  (SQL 查询)   │                ▲                         │
│  └───────┬───────┘                │                         │
│          │           ~/.zcode/cli/db/db.sqlite              │
│          │           (补齐 tool_call_count)                  │
│          ▼                                                  │
│  ┌───────────────┐    ┌───────────────────────────┐         │
│  │ DashboardVM   │───▶│ WidgetStore (App Group)   │         │
│  │  (SwiftUI)    │    │   ↓ snapshot              │         │
│  └───────┬───────┘    └────────────┬──────────────┘         │
│          ▼                         ▼                        │
│     ContentView              WidgetSupport.appex            │
│   (overview/models/tools)   (small/medium/large)            │
└─────────────────────────────────────────────────────────────┘
```

详细架构与数据模型见 [docs/architecture.md](docs/architecture.md)。

## 构建

```bash
# Debug 构建（仅命令行）
./build.sh debug

# 运行
.build/debug/TokenMonitor

# Release 构建（需要 Xcode 项目 + Apple 开发者证书；widget 扩展会嵌入）
./build.sh release
```

> 没有 `.xcodeproj` 时，`release` 会回退到 SwiftPM Universal Binary 构建，**不会包含原生 WidgetKit 扩展**（widget 不可用）。要完整功能，请用 Xcode 打开生成的 `.xcodeproj` 后再 `release`。

## 数据流

1. App 启动 → `SyncRunner.syncNow()` 检查三处授权（Claude projects 目录 / ZCode 库 / ccusage.db）
   - 齐全 → 跑 Swift 端 `ClaudeSync`（扫 JSONL）+ `ZCodeSync`（按 `completed_at` 水位线增量），写入 `ccusage.db`
   - 缺失 → fallback 到旧"假同步真刷新"（数据由终端 `cc-usage sync` 或 launchd 产出）
2. `Aggregator` 用 SQL 聚合 `ccusage.db`（移植自 `ccusage/aggregate.py`）
3. 对 zcode 来源的行，从 `~/.zcode/cli/db/db.sqlite` 补 `tool_call_count` / `reasoning_tokens`
4. 聚合结果经 `WidgetStore` 写入 App Group，WidgetKit 自动 reload

## 路线图

- [x] M1 骨架 + bundle ID
- [x] M2 数据层（UsageDB / ZCodeUsageDB / Aggregator / SyncRunner）
- [x] M3 主面板（range + source + 总览 + Top 模型）
- [x] M4 模型对比 + 工具调用视图
- [x] M5 WidgetKit 三档
- [x] M6 实机 UI 验证
- [x] M7 打包发版（Xcode 项目）
- [x] **0.2.0 Python cc-usage 全套私有化进 Swift**

## ✅ 私有化完成（0.2.0）

`cc-usage sync` 流水线已**原生重写进 Swift**，DMG 装到干净 Mac 上即可独立运行，**不再需要 Python `cc-usage`**：

- **ClaudeSync**：扫 `~/.claude/projects/**/*.jsonl` 增量写库，复刻 `db.py sync()` 的 files mtime 水位 + provider 快照回填（避免会话 append 后整盘刷写供应商的脏数据）
- **ZCodeSync**：按 `completed_at` 水位线增量读 `~/.zcode/cli/db/db.sqlite` 的 `model_usage`，分桶用 `started_at`，靠 `(source, ext_id)` 唯一索引幂等
- **首次启动授权**：需手动通过 NSOpenPanel 授权 3 处（projects 目录 / ZCode db / ccusage.db），授权一次永久生效；另可选授权 `settings.json` 用于给新行打 `ANTHROPIC_BASE_URL` 标签
- **设置页「历史数据修复」**：三个运维命令（去重 / msgid 指纹回填 / 双信号源对账）也 Swift 化，每命令都 **dry-run 预览 → 确认 → 执行**
- **双跑对账通过**：Swift 同步与 Python 基线在 (来源行数 / 每 model token 总量 / 水位线 / ext_id 去重 / claude 17 维度) 五维度零差异

> Python `cc-usage` 仍可继续在终端跑 `backfill / reconcile / dedupe` 三个管理命令做历史修复（与 Swift 端等价，二选一即可）；`docs/com.luoqi.ccusage-sync.plist` 的 launchd 定时同步在 Swift sync 接管后**可由用户手动禁用**。

## License

MIT
