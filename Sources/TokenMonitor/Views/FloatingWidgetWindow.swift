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

    // MARK: - 刘海吸附状态机
    //
    // 状态变换路径：
    //   [visible] --(拖入刘海)--> [pinned] (alpha=0 + ignoresMouseEvents=true)
    //                                |
    //                                | (Timer 轮询，鼠标在刘海区 ≥0.5s)
    //                                ↓
    //                             [peeking] (alpha=1, mouse 接收, frame 贴刘海)
    //                                |
    //                                | (用户拖出刘海区域)
    //                                ↓
    //                             [visible] (复原 preNotchFrame)
    //
    // compact 尺寸(200pt ≈ 刘海宽 195pt) 完全吸进刘海；medium/large 太宽无法
    // 完全吸入，改成"贴刘海下边缘"挂着但可见（半吸附），不触碰摄像头指示灯区。
    private var notchPinned: Bool = false
    private var peeking: Bool = false
    private var preNotchFrame: NSRect?
    private var notchHoverTimer: Timer?
    private var hoverAccumulator: Date?
    private var didMoveObs: NSObjectProtocol?
    /// UserDefaults key: 持久化"上次关闭时是否在吸附态"
    private static let kNotchPinned = "floating_widget_notch_pinned"
    /// UserDefaults key: 进入吸附态前备份的正常位置，关 App 重启后恢复用
    private static let kNotchPreFrame = "floating_widget_notch_preframe"

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
        //
        // 注意：若当前在刘海 pinned 态，不要重写 frame（否则会把浮窗从刘海拽出来）。
        // pinned 态靠 enterNotchPinned() 内部已设过 alpha=0, frame 保留 preNotchFrame，
        // 这里只做 makeKey/orderFront 顺序，跳过 setFrame。
        if let win = window, !notchPinned {
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
        // 用户主动 hide 时清理吸附状态（避免下次 show 时浮窗仍卡在刘海里看不见）
        if notchPinned || peeking {
            stopNotchHoverMonitor()
            notchPinned = false
            peeking = false
            hoverAccumulator = nil
            UserDefaults.standard.set(false, forKey: Self.kNotchPinned)
            window?.alphaValue = 1
            window?.ignoresMouseEvents = false
        }
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

        // 监听窗口移动（拖动浮窗）。每帧触发，据 frame 判定是否进入刘海区域：
        //   - compact 宽接近刘海 → 框与 notchRect 重叠 → 进 pinned 态（alpha=0 消失）
        //   - medium/large 宽远超刘海 → 越过 safeArea.maxY → 钳到"贴刘海下边缘"
        //     （不消失，只是吸附定位），不进 pinned 态
        // 顺便在拖动结束后持久化正常态位置（修探查发现的 bug：saveFrame 之前没人调）。
        didMoveObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowDidMove()
        }

        // 最终强制定：NSPanel 在 createWindow 阶段（panel 未上屏）对 setFrame 的 size
        // 被 silently 忽略，必须在 panel 真正 orderFront 后才能锁住 size。这里先留一次
        // setTime（即便被忽略也兜底），真正生效在 show() 末尾的 post-setFrame。
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size.NSSize), display: true)

        window = panel

        // 若上次关闭时在吸附态，恢复成 pinned（仍隐藏在刘海里等用户悬停)
        if UserDefaults.standard.bool(forKey: Self.kNotchPinned) {
            enterNotchPinned(persistBackup: false)
        }

        renderContent()
    }

    // MARK: - 刘海吸附

    /// 计算 MacBook 刘海在屏幕坐标系下的矩形。
    /// 利用 macOS 12+ 的 `NSScreen.auxiliaryTopLeftArea/RightArea` + `safeAreaInsets`。
    /// 无刘海屏（iMac / 外接屏 / 旧 MacBook）auxiliaryTopLeftArea 等于 nil → 返回 nil → 吸附逻辑自动短路。
    ///
    /// 刘海矩形 = (left.maxX .. right.minX) × (safeTopEdgeBottom .. screen.frame.maxY)
    ///   - safeTopEdgeBottom = screen.frame.maxY - safeAreaInsets.top（即菜单栏/刘海那一整条的底边）
    ///   - 高度 ≈ safeAreaInsets.top ≈ 32pt（菜单栏+刘海区域总高度）
    ///   - 横向 ≈ 刘海宽（约 195pt @ 14" MacBook）
    private func notchRect(on screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let x = left.maxX
        let width = right.minX - left.maxX
        let topBottom = screen.frame.maxY - screen.safeAreaInsets.top
        let height = screen.safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }
        // 刘海仅在顶部那一整条的安全区外，y 范围 = (topBottom, screen.frame.maxY)
        return NSRect(x: x, y: topBottom, width: width, height: height)
    }

    /// 查 panel 当前所在 screen 的刘海矩形（跨屏 fallback）。
    private func currentNotchRect() -> NSRect? {
        guard let win = window else { return nil }
        // 找窗口中心点所在的 screen
        let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? win.screen ?? NSScreen.main else { return nil }
        return notchRect(on: screen)
    }

    /// 拖动事件回调：每帧触发，根据 frame 决定状态切换
    @MainActor
    private func handleWindowDidMove() {
        guard let win = window else { return }

        // peek 态下拖出刘海 → 复原
        if peeking, let notch = currentNotchRect(), !win.frame.intersects(notch) {
            exitNotchPinned()
            return
        }
        if notchPinned { return }   // 已在 pinned 态，不再二次触发

        guard let notch = currentNotchRect() else { return }

        let size = currentSize()
        if win.frame.intersects(notch) {
            // compact: 宽 ≈ 刘海宽 → 进 pinned 态（完全吸进刘海消失）
            // medium/large: 宽远超刘海宽 → 不进 pinned，改成贴刘海下边缘（不消失，半吸附）
            if size == .compact {
                enterNotchPinned(persistBackup: true)
            } else {
                snapBelowNotch(notch: notch)
            }
        }
    }

    /// 进入 pinned 态：隐藏浮窗 + 备份当前 frame + 启动 hover 检测
    @MainActor
    private func enterNotchPinned(persistBackup: Bool) {
        guard !notchPinned, let win = window else { return }
        notchPinned = true
        peeking = false
        preNotchFrame = win.frame
        if persistBackup {
            UserDefaults.standard.set(true, forKey: Self.kNotchPinned)
            UserDefaults.standard.set([
                "x": win.frame.origin.x,
                "y": win.frame.origin.y,
                "w": win.frame.size.width,
                "h": win.frame.size.height,
            ], forKey: Self.kNotchPreFrame)
        }
        // 关键顺序：先调 alpha = 0，再设 ignoresMouseEvents=true
        // 让窗口先视觉消失再让鼠标穿过去，避免瞬态点击漏到浮窗里
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        startNotchHoverMonitor()
        Self.log("notch: enter pinned, prefame=\(win.frame)")
    }

    /// 恢复 visible 态：从备份位置恢复，alpha=1, mouse 接收
    @MainActor
    private func exitNotchPinned() {
        guard let win = window else { return }
        // 顺序：先 mouse 接收，再 alpha=1，避免复原中点击丢失
        win.ignoresMouseEvents = false
        win.alphaValue = 1
        if let pre = preNotchFrame {
            win.setFrame(pre, display: true)
            // 顺手修：拖出后保存正常态位置 (saveFrame 之前没人调)
            saveFrame()
        } else if let pre = savedPreFrameFromDefaults() {
            win.setFrame(pre, display: true)
            saveFrame()
        }
        notchPinned = false
        peeking = false
        hoverAccumulator = nil
        stopNotchHoverMonitor()
        UserDefaults.standard.set(false, forKey: Self.kNotchPinned)
        Self.log("notch: exit pinned, restore=\(preNotchFrame as Any)")
        preNotchFrame = nil
    }

    /// pinned → peek：鼠标悬停刘海 ≥0.5s 后，浮窗 reappear 贴在刘海矩形里
    @MainActor
    private func enterNotchPeek() {
        guard notchPinned, !peeking, let win = window, let notch = currentNotchRect() else { return }
        peeking = true
        win.ignoresMouseEvents = false
        // 把 frame 顶到刘海矩形里（顶天立地吸到刘海）
        win.setFrame(notch, display: true)
        win.alphaValue = 1
        Self.log("notch: peek (hover 持续 ≥0.5s)")
    }

    /// medium/large 半吸附：钳到刘海正下方一档，不消失
    @MainActor
    private func snapBelowNotch(notch: NSRect) {
        guard let win = window else { return }
        let size = currentSize().NSSize
        var frame = win.frame
        // 钳到底边贴 safeArea.maxY（即刘海正下方）
        frame.origin.y = notch.minY - size.height
        frame.size = size
        // 仅当 frame 实际变化才 setFrame，避免无限循环 NSWindowDidMove
        if win.frame != frame {
            win.setFrame(frame, display: true)
            saveFrame()
            Self.log("notch: snap below (medium/large)")
        }
    }

    /// 启动 0.15s/次轮询全局鼠标位置是否进入了刘海区
    private func startNotchHoverMonitor() {
        stopNotchHoverMonitor()
        notchHoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickNotchHover()
            }
        }
        // 用 .common mode 让 status menu 打开时 timer 也继续 fire
        if let timer = notchHoverTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopNotchHoverMonitor() {
        notchHoverTimer?.invalidate()
        notchHoverTimer = nil
        hoverAccumulator = nil
    }

    @MainActor
    private func tickNotchHover() {
        guard notchPinned, !peeking else { return }
        let mouse = NSEvent.mouseLocation
        guard let notch = currentNotchRect() else { return }
        if notch.insetBy(dx: -2, dy: -2).contains(mouse) {
            // 鼠标在刘海区域：开始计时长，持续 ≥0.5s 触发 peek
            if hoverAccumulator == nil {
                hoverAccumulator = Date()
            }
            if Date().timeIntervalSince(hoverAccumulator!) >= 0.5 {
                enterNotchPeek()
            }
        } else {
            hoverAccumulator = nil
        }
    }

    /// 从 UserDefaults 恢复进刘海前的备份位置（用于 App 重启后从吸附态拽出）
    private func savedPreFrameFromDefaults() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.kNotchPreFrame) else {
            return nil
        }
        guard let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat,
              let w = dict["w"] as? CGFloat, let h = dict["h"] as? CGFloat else { return nil }
        return NSRect(x: x, y: y, width: w, height: h)
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
        // 切尺寸时若在 pinned/peek 态，先退出吸附（否则 setFrame 会让浮窗在刘海里
        // 重排成新尺寸，跟原来的"拖出刘海"路径冲突，且 alpha=0 时用户看不到效果）
        if notchPinned || peeking {
            exitNotchPinned()
        }
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
        for pct in [10, 20, 30, 40, 50, 60, 70, 80, 90, 100] {
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
