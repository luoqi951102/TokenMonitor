import SwiftUI
import AppKit

// MARK: - FloatingWidgetWindow
//
// 桌面置顶浮动小窗，代替原生 WidgetKit 小组件（在没装 Xcode 的情况下使用）。
// 特性：
//   - 桌面置顶，跨所有 Space 显示
//   - 半透明毛玻璃 + 圆角，可拖动
//   - 三档尺寸（紧凑 / 中 / 大），右键菜单切换
//   - 位置记忆（重启恢复）
//   - 实时跟随 DashboardViewModel（widget 数据流已就绪）

@MainActor
final class FloatingWidgetWindow {
    static let shared = FloatingWidgetWindow()

    private var window: NSPanel?
    private var viewModel: DashboardViewModel?
    private var menu: NSMenu?
    private var rightClickMonitor: Any?

    enum Size: String, CaseIterable {
        case compact      // 200×100
        case medium       // 320×290（含 streak + Top 模型 + 项目）
        case large        // 360×484（LargeContent 自然高度）

        var NSSize: AppKit.NSSize {
            switch self {
            case .compact: return .init(width: 200, height: 100)
            case .medium:  return .init(width: 320, height: 290)
            case .large:   return .init(width: 360, height: 484)
            }
        }

        var label: String {
            switch self {
            case .compact: return "紧凑"
            case .medium:  return "中"
            case .large:   return "大"
            }
        }
    }

    private init() {}

    // MARK: - Show / Hide

    func show(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
        if window == nil {
            createWindow()
        }
        // 每次显示时刷新菜单勾选状态（防止 size/opacity 改过后菜单不同步）
        rebuildMenuStates()
        Self.log("show: window=\(window != nil ? "ok" : "nil") isVisible=\(window?.isVisible ?? false)")
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        // 关键：NSPanel/sandbox 下 createWindow 时 setFrame 可能被 silently 忽略
        // 直到 panel 真正进入 screen。orderFrontRegardless 后强制再设定一次 size
        // + origin（保持顶对齐），避免 panel size=(0,0) 此时显示尺寸完全不对。
        if let win = window {
            let s = currentSize().NSSize
            var fr = win.frame
            fr.origin.y = fr.maxY - s.height  // 保持顶部对齐
            fr.size = s
            win.setFrame(fr, display: true)
        }
        setVisible(true)
    }

    func hide() {
        window?.orderOut(nil)
        setVisible(false)
    }

    func toggle(viewModel: DashboardViewModel) {
        Self.log("toggle: isVisible=\(isVisible)")
        if window?.isVisible == true {
            hide()
        } else {
            show(viewModel: viewModel)
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data(("[FloatingWidget] " + msg + "\n").utf8))
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Window Creation

    private func createWindow() {
        Self.log("createWindow: begin, size=\(currentSize().rawValue)")
        let size = currentSize()
        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: size.NSSize),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // 恢复位置 + 显式锁定 size（NSPanel 构造后 contentRect 可能被 hosting 的
        // 初始 EmptyView 重置成 (0,0)，必须显式 setFrame 锁定 size.NSSize）
        if let frame = savedFrame() {
            // savedFrame 保存的 size 与当前 currentSize 不一定一致（用户从大档切到中档
            // 后保存），但 size 字段保留旧值 → 覆盖为当前 size.NSSize 强制锁定
            var f = frame
            f.size = size.NSSize
            panel.setFrame(f, display: true)
        } else {
            // 默认屏幕右上角（避开菜单栏和 spotlight）
            if let screenFrame = NSScreen.main?.visibleFrame {
                let origin = NSPoint(
                    x: screenFrame.maxX - size.NSSize.width - 24,
                    y: screenFrame.maxY - size.NSSize.height - 16
                )
                panel.setFrame(NSRect(origin: origin, size: size.NSSize), display: true)
            } else {
                panel.setFrame(NSRect(origin: .zero, size: size.NSSize), display: true)
                panel.center()
            }
        }

        let hosting = NSHostingController(rootView: AnyView(EmptyView())) as NSHostingController<AnyView>
        panel.contentViewController = hosting

        // 关键：让 contentView / hosting.view 透明 + 圆角，
        // 否则窗口默认矩形会从 ZStack 圆角矩形的四个角漏出来
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        hosting.view.layer?.cornerRadius = 16
        hosting.view.layer?.masksToBounds = true

        // 右键菜单：切尺寸 / 透明度 / 打开完整面板 / 关闭
        let menu = buildMenu(size: size)
        self.menu = menu

        // 把菜单挂到 hosting.view 上
        hosting.view.menu = menu

        // 监听全局右键事件 - 如果鼠标在窗口内，弹出菜单
        // （hosting.view.menu 在 SwiftUI 内容上有时不响应，这是兜底方案）
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let window = self.window, window.isVisible else { return event }
            // event.locationInWindow 是在 event.window 坐标系下的点
            // 转换到屏幕坐标
            let pointInScreen = event.window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin ?? .zero
            if window.frame.contains(pointInScreen) {
                self.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                return nil  // 消费事件
            }
            return event
        }

        // 最终强制定：NSPanel 在 createWindow 阶段（panel 未上屏）对 setFrame 的 size
        // 被 silently 忽略，必须在 panel 真正 orderFront 后才能锁住 size。这里先留一次
        // setTime（即便被忽略也兜底），真正生效在 show() 末尾的 post-setFrame。
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size.NSSize), display: true)

        window = panel
        renderContent()
    }

    // MARK: - Render

    private func renderContent() {
        guard let window, let viewModel else {
            Self.log("renderContent: ❌ window=\(window != nil) viewModel=\(viewModel != nil)")
            return
        }
        guard let hosting = window.contentViewController as? NSHostingController<AnyView> else {
            Self.log("renderContent: ❌ contentViewController type mismatch: \(String(describing: window.contentViewController))")
            return
        }
        let size = currentSize()
        let view = FloatingWidgetView(viewModel: viewModel, size: size)
            .environment(\.floatingWidgetSize, size)
        hosting.rootView = AnyView(view)
        Self.log("renderContent: ✅ rootView updated, size=\(size.rawValue)")
    }

    // MARK: - Menu Actions

    @objc private func resizeTo(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = Size(rawValue: raw) else { return }
        UserDefaults.standard.set(s.rawValue, forKey: "floating_widget_size")
        // 包 withAnimation 让 SwiftUI content 的 transition（opacity + scale）生效
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyCurrentSize()
            self.rebuildMenuStates()
        }
    }

    /// 应用当前 size 到窗口（调整 frame 大小，保持左上角位置）
    /// 注意：用 animate: false，避免窗口动画+内容重渲染叠加导致的"回勾"。
    /// 内容切换的丝滑感由 FloatingWidgetView 里的 transition 负责。
    private func applyCurrentSize() {
        guard let window else { return }
        let newSize = currentSize().NSSize
        var frame = window.frame
        // 保持顶部对齐（macOS 坐标系 y 从底部算）
        frame.origin.y = frame.maxY - newSize.height
        frame.size = newSize
        // 禁用动画，立即应用（避免窗口边框动画 + 内容动画叠加闪烁）
        window.setFrame(frame, display: true, animate: false)
        renderContent()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(v, forKey: "floating_widget_opacity")
        // 通知正在显示的视图刷新
        NotificationCenter.default.post(name: .floatingWidgetOpacityChanged, object: v)
        rebuildMenuStates()
    }

    /// 构建右键菜单
    private func buildMenu(size: Size) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for s in Size.allCases {
            let item = NSMenuItem(title: "尺寸：\(s.label)", action: #selector(resizeTo(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            item.state = s == size ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let opacityItem = NSMenuItem(title: "背景不透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for pct in [60, 75, 85, 92, 100] {
            let it = NSMenuItem(title: "\(pct)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = Double(pct) / 100.0
            let current = UserDefaults.standard.object(forKey: "floating_widget_opacity") as? Double ?? 0.92
            it.state = abs(current - Double(pct) / 100.0) < 0.01 ? .on : .off
            opacityMenu.addItem(it)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        let openPanel = NSMenuItem(title: "打开完整面板", action: #selector(openMainPanel), keyEquivalent: "")
        openPanel.target = self
        menu.addItem(openPanel)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭小窗", action: #selector(menuClose), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func openMainPanel() {
        // 通过通知让 MenuBarManager 打开主面板
        NotificationCenter.default.post(name: .floatingWidgetRequestOpenMain, object: nil)
    }

    @objc private func menuClose() {
        setVisible(false)
        hide()
    }

    /// 显示状态持久化（用于 App 重启自动恢复）
    private func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "floating_widget_visible")
    }

    /// App 启动时调用：如果上次是可见状态，自动恢复
    func restoreIfNeeded(viewModel: DashboardViewModel) {
        let wasVisible = UserDefaults.standard.object(forKey: "floating_widget_visible") as? Bool ?? false
        if wasVisible {
            show(viewModel: viewModel)
        }
    }

    private func rebuildMenuStates() {
        // 菜单存在 self.menu 上（hosting.view.menu 引用同一个对象）
        guard let menu = self.menu else { return }
        let size = currentSize()
        for item in menu.items {
            if let raw = item.representedObject as? String, let s = Size(rawValue: raw) {
                item.state = s == size ? .on : .off
            }
            // 透明度子菜单的勾
            if let sub = item.submenu {
                let current = UserDefaults.standard.object(forKey: "floating_widget_opacity") as? Double ?? 0.92
                for subItem in sub.items {
                    if let v = subItem.representedObject as? Double {
                        subItem.state = abs(current - v) < 0.01 ? .on : .off
                    }
                }
            }
        }
    }

    // MARK: - Persistence

    private func currentSize() -> Size {
        if let raw = UserDefaults.standard.string(forKey: "floating_widget_size"),
           let s = Size(rawValue: raw) {
            return s
        }
        // 默认档位：大（360×420 完整看板）
        return .large
    }

    private func savedFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "floating_widget_frame") else {
            return nil
        }
        guard let x = dict["x"] as? CGFloat,
              let y = dict["y"] as? CGFloat,
              let w = dict["w"] as? CGFloat,
              let h = dict["h"] as? CGFloat else {
            return nil
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set([
            "x": frame.origin.x,
            "y": frame.origin.y,
            "w": frame.size.width,
            "h": frame.size.height,
        ], forKey: "floating_widget_frame")
    }
}

// MARK: - Right Click Menu View
//
// borderless NSPanel 默认不响应 panel.menu。
// 用 NSView 子类重写 rightMouseDown，手动弹出菜单 + 接管 SwiftUI 内容。

private final class RightClickMenuView: NSView {
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = self.menu {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // 让 contentView 自动撑满 panel
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.width, .height]
        wantsLayer = true
    }
}

// MARK: - Widget Panel (支持 nonactivating)

private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // 不抢焦点（点击小窗不会让其他 App 失活）
    override var acceptsFirstResponder: Bool { false }

    override var contentView: NSView? {
        didSet {
            // contentView 默认带白色背景，设为透明 + 圆角，避免四个角露出矩形尖角
            contentView?.wantsLayer = true
            contentView?.layer?.backgroundColor = .clear
            contentView?.layer?.cornerRadius = 16
            contentView?.layer?.masksToBounds = true
        }
    }
}

// MARK: - Size Environment Key

private struct FloatingWidgetSizeKey: EnvironmentKey {
    // 默认档位：大（与 currentSize() 保持一致）
    static let defaultValue: FloatingWidgetWindow.Size = .large
}
extension EnvironmentValues {
    var floatingWidgetSize: FloatingWidgetWindow.Size {
        get { self[FloatingWidgetSizeKey.self] }
        set { self[FloatingWidgetSizeKey.self] = newValue }
    }
}
