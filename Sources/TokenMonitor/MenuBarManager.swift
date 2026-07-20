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

    private lazy var menuBarIcon: NSImage? = {
        // SF Symbols 渲染为模板图，支持暗黑模式
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Token Monitor")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        image?.size = Theme.menuBarIconSize
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
