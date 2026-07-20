# Token Monitor

一个 macOS 菜单栏 + WidgetKit 小组件，监控本地 LLM token 用量、模型对比与工具调用。**不含费用、不含余额、不上传任何数据**。

数据来源：[`cc-usage`](https://github.com/luoqi951102/token-count)（同步 Claude Code + ZCode 的本地日志到 `~/.claude/ccusage.db`）。

## 特性

- 📊 **菜单栏面板**：range（今日 / 本周 / 本月 / 全部）× source（全部 / Claude / ZCode）双维度筛选
- 🤖 **模型对比**：input / cache_write / cache_read / output / total / msgs / tool_calls 表 + 堆叠构成图，**模型无关**（日志里是什么模型就显示什么）
- 🔧 **工具调用**：哪个模型最爱调工具、调用密度、日趋势（仅 ZCode 来源有数据）
- 🎛 **WidgetKit 三档**：Small / Medium / Large 桌面小组件
- 🔒 **只读**：所有数据库 `?mode=ro` 打开，从不动你的源日志
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
│  ┌───────────────┐    ┌───────────────┐                    │
│  │  SyncRunner   │───▶│   cc-usage    │ (Python, 外部)     │
│  │ (定时 + 手动) │    │     sync      │                    │
│  └───────────────┘    └───────┬───────┘                    │
│         ▼                     │                            │
│  ┌───────────────┐            ▼                            │
│  │  Aggregator   │◀── ~/.claude/ccusage.db  (只读)         │
│  │  (SQL 查询)   │            ▲                            │
│  └───────┬───────┘            │                            │
│          │           ~/.zcode/cli/db/db.sqlite             │
│          │           (补齐 tool_call_count)                 │
│          ▼                                                 │
│  ┌───────────────┐    ┌───────────────────────────┐        │
│  │ DashboardVM   │───▶│ WidgetStore (App Group)   │        │
│  │  (SwiftUI)    │    │   ↓ snapshot              │        │
│  └───────┬───────┘    └────────────┬──────────────┘        │
│          ▼                         ▼                       │
│     ContentView              WidgetSupport.appex           │
│   (overview/models/tools)   (small/medium/large)           │
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

1. App 启动 → `SyncRunner` 异步跑 `cc-usage sync`（增量同步 Claude JSONL + ZCode SQLite 到 `ccusage.db`）
2. `Aggregator` 用 SQL 聚合 `ccusage.db`（移植自 `ccusage/aggregate.py`）
3. 对 zcode 来源的行，从 `~/.zcode/cli/db/db.sqlite` 补 `tool_call_count` / `reasoning_tokens`
4. 聚合结果经 `WidgetStore` 写入 App Group，WidgetKit 自动 reload

## 路线图

- [x] M1 骨架 + bundle ID
- [x] M2 数据层（UsageDB / ZCodeUsageDB / Aggregator / SyncRunner）
- [x] M3 主面板（range + source + 总览 + Top 模型）
- [x] M4 模型对比 + 工具调用视图
- [x] M5 WidgetKit 三档
- [ ] M6 实机 UI 验证
- [ ] M7 打包发版（Xcode 项目）

## License

MIT
