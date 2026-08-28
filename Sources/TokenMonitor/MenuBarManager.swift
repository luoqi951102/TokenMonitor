import Cocoa
import SwiftUI
import Combine

// MARK: - Menu Bar Manager

@MainActor
final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private let statusMenu = NSMenu()
    private var monitor: Any?
    private var autoCloseTimer: Timer?
    private var hoverStateTimer: Timer?
    private var isMouseInsidePanel = false
    private var lastStatusButtonScreenFrame: NSRect?
    private var cancellables = Set<AnyCancellable>()

    let viewModel = DashboardViewModel()

    private lazy var settingsWindowController: SettingsWindowController = {
        SettingsWindowController(viewModel: viewModel)
    }()

    // MARK: - Init

    override init() {
        super.init()
        setupStatusItem()
        setupPanel()
        observeViewModel()
    }

    func bootstrap() {
        viewModel.bootstrap()
        // 启动后立即显示桌面浮动小窗（用户不用手动触发）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            FloatingWidgetWindow.shared.show(viewModel: self.viewModel)
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        updateStatusBarButton(button)
        button.action = #selector(togglePanel)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        configureStatusMenu()
    }

    private func configureStatusMenu() {
        statusMenu.autoenablesItems = false
        statusMenu.removeAllItems()

        addStatusMenuItem(title: "立即同步", action: #selector(manualSync), keyEquivalent: "s")
        addStatusMenuItem(title: "刷新视图", action: #selector(manualRefresh), keyEquivalent: "r")
        statusMenu.addItem(.separator())
        // 桌面浮动小窗切换（带状态显示）
        let widgetItem = NSMenuItem(title: "显示桌面小窗", action: #selector(toggleFloatingWidget), keyEquivalent: "w")
        widgetItem.target = self
        widgetItem.isEnabled = true
        widgetItem.tag = 100
        statusMenu.addItem(widgetItem)
        statusMenu.addItem(.separator())
        addStatusMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        statusMenu.addItem(.separator())
        addStatusMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
    }

    @objc private func toggleFloatingWidget() {
        FloatingWidgetWindow.shared.toggle(viewModel: viewModel)
    }

    private func addStatusMenuItem(title: String, action: Selector, keyEquivalent: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = true
        statusMenu.addItem(item)
    }

    // MARK: - Panel

    private func setupPanel() {
        let hostingController = NSHostingController(
            rootView: ContentView(
                viewModel: viewModel,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onClose: { [weak self] in self?.closePanel() }
            )
        )

        panel = FloatingPanel(
            contentViewController: hostingController,
            contentSize: desiredPanelSize
        )
    }

    @objc func togglePanel() {
        guard let button = statusItem.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp ||
            NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showStatusMenu(button: button)
            return
        }

        if panel.isVisible {
            closePanel()
        } else {
            showPanel(button: button)
        }
    }

    private func showStatusMenu(button: NSStatusBarButton) {
        closePanel()
        // 更新"桌面小窗"菜单项的状态文字
        if let widgetItem = statusMenu.item(withTag: 100) {
            widgetItem.title = FloatingWidgetWindow.shared.isVisible ? "隐藏桌面小窗" : "显示桌面小窗"
        }
        statusItem.menu = statusMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    func showPanel(button: NSStatusBarButton) {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        if let screen = button.window?.screen ?? NSScreen.main {
            resizePanelToMatchContent(keepingTopEdge: false)
            let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
            lastStatusButtonScreenFrame = buttonRect

            var origin = NSPoint(
                x: buttonRect.midX - panel.frame.width / 2,
                y: buttonRect.minY - panel.frame.height - Theme.panelTopGap
            )

            if origin.x < screen.visibleFrame.minX + 4 {
                origin.x = screen.visibleFrame.minX + 4
            }
            if origin.x + panel.frame.width > screen.visibleFrame.maxX - 4 {
                origin.x = screen.visibleFrame.maxX - panel.frame.width - 4
            }

            panel.setFrameOrigin(origin)
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        startHoverStateMonitoring()
        refreshHoverState()
        schedulePanelAutoClose()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        hoverStateTimer?.invalidate()
        hoverStateTimer = nil
        isMouseInsidePanel = false
        panel.orderOut(nil)
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func schedulePanelAutoClose() {
        autoCloseTimer?.invalidate()
        guard panel.isVisible, shouldPausePanelAutoClose == false else { return }
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        }
    }

    private func startHoverStateMonitoring() {
        hoverStateTimer?.invalidate()
        hoverStateTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshHoverState()
            }
        }
    }

    private var shouldPausePanelAutoClose: Bool {
        isMouseInsidePanel
    }

    private func refreshHoverState() {
        guard panel.isVisible else { return }

        let mouseLocation = NSEvent.mouseLocation
        let wasPaused = shouldPausePanelAutoClose

        isMouseInsidePanel = panel.frame.contains(mouseLocation)

        let isPaused = shouldPausePanelAutoClose
        if isPaused {
            autoCloseTimer?.invalidate()
            autoCloseTimer = nil
        } else if wasPaused != isPaused || autoCloseTimer == nil {
            schedulePanelAutoClose()
        }
    }

    // MARK: - ViewModel Observation

    private func observeViewModel() {
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resizePanelToMatchContent(keepingTopEdge: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu Bar Icon
    //
    // 不再依赖 SF Symbol `chart.bar.xaxis`（任何开发者都能用、产品没视觉身份）。
    // 自绘单色三柱 + baseline 几何符号，传达 "token 递增 + 测量基线" 的产品语义：
    //   - 三根递增竖柱：input → cache → output 的 token 流转
    //   - 底部水平基线：测量 / 监控的视觉锚点
    // 单色 + isTemplate = true，菜单栏深浅模式自动着色，跟 Apple 工具图标等价。

    private lazy var menuBarIcon: NSImage? = {
        let size = Theme.menuBarIconSize                  // 18×18
        let image = NSImage(size: size)
        image.lockFocus()

        // 柱子布局：左中右三根，等距递增
        // 16×16 viewBox 内坐标（再 scale 到实际 size）
        let barWidth: CGFloat = 2.4
        let barRadius: CGFloat = 0.6
        let baselineY: CGFloat = 3.0
        let baselineHeight: CGFloat = 1.5

        // 三根柱子的 (x, height)：递增形如 input→output
        let bars: [(CGFloat, CGFloat)] = [
            (3.5, 5.5),    // 第 1 根：最矮
            (7.8, 8.5),    // 第 2 根：中
            (12.1, 11.5),  // 第 3 根：最高
        ]
        // 把 16×16 viewBox 映射到 18×18 image：每坐标乘 scale 并偏移
        let scale = size.width / 16.0
        let transform = NSAffineTransform()
        transform.scale(by: scale)

        NSGraphicsContext.current?.saveGraphicsState()
        transform.concat()

        // 柱子（圆角矩形）
        for (x, h) in bars {
            let rect = NSRect(x: x, y: baselineY + baselineHeight, width: barWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: barRadius, yRadius: barRadius)
            path.fill()
        }

        // 底部基线：略宽于柱阵，opacity 0.55
        // appleTemplate 模式下颜色会被 menu bar tint 自动 mask，因此用 black + alpha 表示淡化
        let baselineRect = NSRect(x: 2.5, y: baselineY, width: 13, height: baselineHeight)
        let baselinePath = NSBezierPath(roundedRect: baselineRect, xRadius: 0.5, yRadius: 0.5)
        NSColor.black.withAlphaComponent(0.55).setFill()
        baselinePath.fill()

        NSGraphicsContext.current?.restoreGraphicsState()
        image.unlockFocus()

        image.isTemplate = true                            // 单色模板：菜单栏深浅自动适配
        image.accessibilityDescription = "Token Monitor"
        return image
    }()

    private func updateStatusBarButton(_ button: NSStatusBarButton) {
        button.image = menuBarIcon
        button.title = ""
        button.imagePosition = .imageOnly
    }

    // MARK: - Actions

    @objc private func manualSync() {
        Task { await viewModel.manualSync() }
    }
    @objc private func manualRefresh() {
        viewModel.refresh()
        viewModel.pushWidgetSnapshot()
    }
    @objc private func openSettings() {
        presentSettingsWindow()
    }

    private func presentSettingsWindow() {
        if panel.isVisible {
            let frame = panel.frame
            let screen = panel.screen ?? NSScreen.main
            closePanel()
            settingsWindowController.show(anchorFrame: frame, screen: screen)
            return
        }

        if let button = statusItem.button,
           let buttonWindow = button.window {
            let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            lastStatusButtonScreenFrame = frame
            settingsWindowController.show(anchorFrame: frame, screen: buttonWindow.screen ?? NSScreen.main)
            return
        }

        settingsWindowController.show(anchorFrame: lastStatusButtonScreenFrame, screen: NSScreen.main)
    }

    func handleDeepLink(url: URL) {
        guard let host = url.host else { return }
        switch host {
        case "settings":
            presentSettingsWindow()
        case "refresh":
            Task { await viewModel.manualSync() }
        default:
            // 暂未支持的深链，统一打开面板
            if let button = statusItem.button {
                showPanel(button: button)
            }
        }
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    func cleanup() {
        viewModel.shutdown()
        closePanel()
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
        if let button = statusItem.button {
            button.action = nil
            button.target = nil
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

private extension MenuBarManager {
    var desiredPanelSize: NSSize {
        NSSize(width: Theme.panelWidth, height: Theme.panelDashboardHeight)
    }

    func resizePanelToMatchContent(keepingTopEdge: Bool) {
        guard panel != nil else { return }
        let newSize = desiredPanelSize
        guard panel.frame.size != newSize else { return }

        let oldFrame = panel.frame
        var newOrigin = oldFrame.origin
        if keepingTopEdge {
            newOrigin.y = oldFrame.maxY - newSize.height
        }

        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: panel.isVisible)
    }
}

// MARK: - Floating Panel

private final class FloatingPanel: NSWindow {
    init(contentViewController: NSViewController, contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.contentViewController = contentViewController
        self.setContentSize(contentSize)
        self.contentViewController?.view.wantsLayer = true
        self.contentViewController?.view.layer?.cornerRadius = Theme.panelCornerRadius
        self.contentViewController?.view.layer?.masksToBounds = true
        self.contentView?.wantsLayer = true
        self.contentView?.layer?.cornerRadius = Theme.panelCornerRadius
        self.contentView?.layer?.masksToBounds = true
        self.contentView?.superview?.wantsLayer = true
        self.contentView?.superview?.layer?.cornerRadius = Theme.panelCornerRadius

        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isReleasedWhenClosed = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
