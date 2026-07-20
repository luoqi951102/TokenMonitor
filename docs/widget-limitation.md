# Widget 限制说明

## TL;DR

**Widget 代码已完成并通过编译，但在没有完整 Xcode IDE 的机器上无法打包成可用的 `.appex`**。这是 Apple 的硬性限制，不是项目的问题。

## 现状

| 组件 | 状态 |
|---|---|
| Widget Swift 代码（`Sources/WidgetSupport/`） | ✅ 完成 |
| `WidgetSupport` 二进制（SwiftPM 编译） | ✅ 326 KB |
| Widget 三档 UI（Small / Medium / Large） | ✅ 完成 |
| App Group snapshot 数据流 | ✅ 已验证（`widget_snapshot` 真实写入） |
| `.appex` bundle 构造（Info.plist + 二进制 + 签名） | ✅ 手工构造成功 |
| **widget extension 进程能加载** | ❌ `Failed to create running extension of type: 'viewBridgeUI'` |
| **桌面挂载** | ❌ 未到达 |

## 失败的根本原因

`ExtensionFoundation/EXRunningExtension.swift:36: Fatal error: Failed to create running extension of type: 'viewBridgeUI'`

参考 [CodexBar issue #1095](https://github.com/steipete/CodexBar/issues/1095)（同类型项目，相同症状）：

> SwiftPM 没有原生的 "widget extension target" 概念，无法应用 widget 扩展需要的 entry-point / linker 设置。这些设置只有 Xcode 的 Widget Extension 模板会提供（注入 `EXExtension` principal class、`com.apple.product-type.app-extension` product type、运行时阻塞 runloop 等）。
>
> 在 macOS 26 (Tahoe) 上，SwiftPM 构建的 widget 二进制即使 Info.plist 正确，加载时也会被 `ExtensionFoundation` 拒绝。

简而言之：widget extension 必须用 **Xcode IDE 的 Widget Extension target 模板**构建，SwiftPM / `swift build` 命令行路径走不通。

## 已尝试的方案

按 [CodexBar issue #1095](https://github.com/steipete/CodexBar/issues/1095) 给出的全部方案都试过：

1. ✅ 手工构造 `.appex` bundle（Info.plist + Mach-O + Resources）
2. ✅ 正确的 `NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`
3. ✅ `codesign --deep --strict` 嵌套签名（先内后外）
4. ✅ `pluginkit -a` 注册
5. ✅ 杀 chronod / NotificationCenter / Dock 重刷
6. ✅ 简化 `NSExtension`（去掉 `NSExtensionAttributes`）
7. ❌ 全部失败，widget 进程启动即崩溃

## 启用 widget 的步骤（需要装 Xcode）

```bash
# 1. 从 App Store 安装 Xcode（约 15 GB）
# 2. 切换 developer dir
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# 3. 在 Xcode 里打开项目
open Package.swift    # Xcode 会基于 Package.swift 创建隐式项目

# 4. File → New → Target → Widget Extension
#    - Product Name: WidgetSupport
#    - Bundle ID 后缀: widget（生成 com.luoqi.tokenmonitor.widget）
#    - 勾选 "Include Configuration App Intent" 否
#    - 嵌入到 TokenMonitor target

# 5. 把 Sources/WidgetSupport/ 里的 Swift 文件加入新 target
#    （TimelineProvider.swift / WidgetViews.swift / DeepSeekWidget.swift）

# 6. 配置 App Group（Signing & Capabilities → +App Groups）
#    添加 N5YV5FV235.group.com.luoqi.tokenmonitor

# 7. 用 Xcode 的 Product → Archive（或 build.sh 的 build_release_xcode 路径）
./build.sh release    # 这次会走 Xcode 路径嵌入真正的 .appex
```

## 参考资料

- [CodexBar issue #1095](https://github.com/steipete/CodexBar/issues/1095) — 同类型项目相同症状
- [Apple — Creating a Widget Extension](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)
- [Make your Mac app's extensions immediately available (pluginkit)](https://gist.github.com/insidegui/ca0f0ac4e53acd82281191cd7b953366)
