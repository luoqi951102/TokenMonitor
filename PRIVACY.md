# Privacy

Token Monitor is a fully local macOS utility. No network requests are made by the app itself — all data is read from local files on your Mac.

## Data Sources

The app reads (read-only) from:

```text
~/.claude/ccusage.db              # 由 cc-usage (token-count) 同步生成
~/.zcode/cli/db/db.sqlite         # ZCode 原生数据库（只读补齐 tool_call_count）
~/.claude/projects/*/*.jsonl      # 间接：cc-usage 解析后写入 ccusage.db
```

No data is uploaded or sent to any server. The app does not embed any analytics, telemetry, or third-party tracking.

## Local Cache

UI state (selected range / source) is stored in `UserDefaults` under the bundle identifier `com.luoqi.tokenmonitor`:

```text
~/Library/Preferences/com.luoqi.tokenmonitor.plist
```

## WidgetKit App Group

Aggregated snapshots are shared with `WidgetSupport.appex` through the App Group:

```text
N5YV5FV235.group.com.luoqi.tokenmonitor
```

The snapshot contains only display data: total tokens, message/tool-call counts, top models, recent daily trend, and last sync time. **No API keys, no secrets, no file contents.**

## External Process

The app spawns `cc-usage sync` (from the [token-count](https://github.com/luoqi951102/token-count) project) as a child process. Its location is auto-detected from `PATH` or `~/.local/bin/cc-usage`, and can be manually configured in Settings.
