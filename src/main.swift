import AppKit
import ApplicationServices
import Darwin

// MARK: - 窗口信息（Accessibility API）

final class WinInfo {
    let title: String
    let minimized: Bool
    let ref: AXUIElement
    init(title: String, minimized: Bool, ref: AXUIElement) {
        self.title = title
        self.minimized = minimized
        self.ref = ref
    }
    /// 前置并聚焦这个具体窗口（跨桌面切换由系统处理）
    func raise() {
        AXUIElementPerformAction(ref, kAXRaiseAction as CFString)
    }
}

private func axTrusted() -> Bool { AXIsProcessTrusted() }

private func axWindows(for app: NSRunningApplication) -> [WinInfo] {
    let appRef = AXUIElementCreateApplication(app.processIdentifier)
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &out) == .success,
          let windows = out as? [AXUIElement] else { return [] }
    var result: [WinInfo] = []
    for w in windows {
        var t: CFTypeRef?
        var title = ""
        if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success,
           let s = t as? String {
            title = s
        }
        var m: CFTypeRef?
        let minimized = AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m) == .success
            && (m as? Bool ?? false)
        result.append(WinInfo(title: title, minimized: minimized, ref: w))
    }
    return result
}

private func axCloseWindow(_ win: AXUIElement) {
    var b: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &b) == .success,
          let raw = b else { return }
    let btn = unsafeBitCast(raw, to: AXUIElement.self)
    AXUIElementPerformAction(btn, kAXPressAction as CFString)
}

// MARK: - 进程树收集（彻底关闭：主进程 + 后代 + 同 bundle 路径进程）

private func collectProcessTree(rootPid: pid_t, bundlePath: String?) -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size: Int = 0
    sysctl(&mib, 3, nil, &size, nil, 0)
    guard size > 0 else { return [rootPid] }
    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [rootPid] }

    var children: [pid_t: [pid_t]] = [:]
    var result: Set<pid_t> = [rootPid]
    for p in procs where p.kp_proc.p_pid > 0 && p.kp_eproc.e_ppid > 0 {
        children[p.kp_eproc.e_ppid, default: []].append(p.kp_proc.p_pid)
    }
    var queue: [pid_t] = [rootPid]
    while !queue.isEmpty {
        let cur = queue.removeFirst()
        for child in children[cur] ?? [] where !result.contains(child) {
            result.insert(child)
            queue.append(child)
        }
    }
    // 同 bundle 路径的独立进程（不经主进程派生的辅助进程）
    if let bp = bundlePath {
        for p in procs {
            let pid = p.kp_proc.p_pid
            guard pid > 0, !result.contains(pid) else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, 4096) > 0 {
                let path = String(cString: buf)
                if path.hasPrefix(bp) { result.insert(pid) }
            }
        }
    }
    return Array(result)
}

private func killTreeIfAlive(_ pids: [pid_t]) {
    for pid in pids where pid > 1 {
        if kill(pid, 0) == 0 || errno == EPERM {
            kill(pid, SIGKILL)
        }
    }
}

// MARK: - 应用卡片（图标 + 名称 + PID/窗口数 + ✕）

final class AppCardView: NSView {
    let app: NSRunningApplication
    private weak var panel: AppDelegate?

    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isClosing = false

    init(app: NSRunningApplication, windowsCount: Int, panel: AppDelegate) {
        self.app = app
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true

        let name = app.localizedName ?? "未知应用"
        toolTip = windowsCount > 1
            ? "「\(name)」有 \(windowsCount) 个窗口 · 点 ✕ 彻底关闭 · 点卡片激活"
            : "点击激活「\(name)」，点右上角 ✕ 彻底关闭"

        let iconView = NSImageView(image: app.icon ?? NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // 有多个窗口时显示数量徽章
        let pidText = windowsCount > 1 ? "PID \(app.processIdentifier) · \(windowsCount) 窗口" : "PID \(app.processIdentifier)"
        let pidLabel = NSTextField(labelWithString: pidText)
        pidLabel.font = .systemFont(ofSize: 10)
        pidLabel.textColor = .secondaryLabelColor
        pidLabel.alignment = .center
        pidLabel.lineBreakMode = .byTruncatingTail
        pidLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "彻底关闭整个应用（含所有辅助进程）"
        closeButton.setAccessibilityLabel("彻底关闭 \(name)")
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(pidLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            pidLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            pidLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pidLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }

    private func refreshAppearance() {
        guard let layer else { return }
        layer.backgroundColor = (isHovering ? NSColor.controlAccentColor : NSColor.white)
            .withAlphaComponent(isHovering ? 0.18 : 0.10).cgColor
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        closeButton.contentTintColor = isHovering ? .systemRed : .secondaryLabelColor
    }

    func markClosing() {
        isClosing = true
        closeButton.isEnabled = false
        alphaValue = 0.35
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; refreshAppearance() }
    override func mouseExited(with event: NSEvent) { isHovering = false; refreshAppearance() }

    override func mouseDown(with event: NSEvent) {
        guard !isClosing else { return }
        // 打开 bundle 等同于点击 Dock 图标：自动切换到该应用所在的桌面并前置
        if let bundleURL = app.bundleURL {
            NSWorkspace.shared.open(bundleURL)
        }
        if #available(macOS 14.0, *) {
            app.activate(from: .current)
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    @objc private func closeClicked() {
        panel?.forceClose(app, card: self)
    }
}

// MARK: - 窗口卡片（与应用主卡片同款的大卡片：图标 + 标题 + ✕）
// 点击打开该窗口，✕ 只关闭这一个窗口；最小化的窗口半透明显示

final class WindowCardView: NSView {
    static let height: CGFloat = 104

    private let win: WinInfo
    private let app: NSRunningApplication
    private weak var panel: AppDelegate?

    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(win: WinInfo, app: NSRunningApplication, panel: AppDelegate) {
        self.win = win
        self.app = app
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true

        let appName = app.localizedName ?? "未知应用"
        let displayTitle = win.title.isEmpty ? appName : win.title
        toolTip = "「\(appName)」的窗口：\(displayTitle)\n点击打开这个窗口 · 点 ✕ 只关闭它"
        setAccessibilityLabel("窗口卡片 \(appName) \(displayTitle)")

        let iconView = NSImageView(image: app.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: displayTitle)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textColor = win.minimized ? .secondaryLabelColor : .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: "\(appName) · \(win.minimized ? "已最小化" : "点击打开")")
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭窗口")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "关闭窗口「\(displayTitle)」"
        closeButton.setAccessibilityLabel("关闭窗口 \(displayTitle)")
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),

            nameLabelCommon(titleLabel, below: iconView),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        if win.minimized { alphaValue = 0.6 }
        refreshAppearance()
    }

    private func nameLabelCommon(_ label: NSTextField, below icon: NSImageView) -> NSLayoutConstraint {
        label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func refreshAppearance() {
        guard let layer else { return }
        layer.backgroundColor = (isHovering ? NSColor.controlAccentColor : NSColor.white)
            .withAlphaComponent(isHovering ? 0.18 : 0.10).cgColor
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        closeButton.contentTintColor = isHovering ? .systemRed : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true; refreshAppearance() }
    override func mouseExited(with event: NSEvent) { isHovering = false; refreshAppearance() }

    override func mouseDown(with event: NSEvent) {
        // 前置这个具体窗口（最小化的自动还原）
        win.raise()
    }

    @objc private func closeClicked() {
        closeButton.isEnabled = false
        alphaValue = 0.35
        axCloseWindow(win.ref)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.panel?.reload(force: true)
        }
    }
}

// MARK: - 统一卡片流（应用卡与窗口卡同尺寸，连续流式排列，不留空位）

final class CardGridView: NSView {
    static let cardSize = NSSize(width: 120, height: 104)
    static let hSpacing: CGFloat = 12
    static let vSpacing: CGFloat = 12
    static let padding: CGFloat = 10

    private var cards: [NSView] = []

    override var isFlipped: Bool { true }

    func setCards(_ newCards: [NSView]) {
        cards.forEach { $0.removeFromSuperview() }
        cards = newCards
        cards.forEach { addSubview($0) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var columns: Int {
        let avail = max(bounds.width - 2 * Self.padding, 0)
        return max(Int((avail + Self.hSpacing) / (Self.cardSize.width + Self.hSpacing)), 1)
    }

    override var intrinsicContentSize: NSSize {
        let cols = columns
        let rows = max((cards.count + cols - 1) / cols, 1)
        return NSSize(width: bounds.width,
                      height: Self.padding * 2 + CGFloat(rows) * Self.cardSize.height + CGFloat(rows - 1) * Self.vSpacing)
    }

    override func layout() {
        super.layout()
        let cols = columns
        let gridWidth = CGFloat(cols) * Self.cardSize.width + CGFloat(cols - 1) * Self.hSpacing
        let startX = (bounds.width - gridWidth) / 2
        for (index, card) in cards.enumerated() {
            let row = index / cols
            let column = index % cols
            card.frame = NSRect(
                x: startX + CGFloat(column) * (Self.cardSize.width + Self.hSpacing),
                y: Self.padding + CGFloat(row) * (Self.cardSize.height + Self.vSpacing),
                width: Self.cardSize.width,
                height: Self.cardSize.height
            )
        }
        invalidateIntrinsicContentSize()
    }
}

// MARK: - 面板控制器

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var cardGrid: CardGridView!
    private var emptyLabel: NSTextField!
    private var countLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!
    private var authBanner: NSButton!
    private var authBannerHeight: NSLayoutConstraint!
    private var pinButton: NSButton!
    private var isPinned = false
    private let pinKey = "panelAlwaysOnTop"

    private var apps: [NSRunningApplication] = []
    private var lastSignature: [String] = []
    private var reloadCounter = 0
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusResetItem: DispatchWorkItem?

    private let defaultStatus = "✕ 彻底关闭应用 · 点窗口卡片打开/关单个窗口 · 📌 置顶"

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        setPinned(UserDefaults.standard.bool(forKey: pinKey), silent: true)
        reload(force: true)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() })
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: 界面搭建

    private func buildUI() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 596, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "应用关闭面板"
        win.minSize = NSSize(width: 360, height: 480)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.center()
        window = win

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 596, height: 680))
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        win.contentView = blur
        let content = blur

        countLabel = NSTextField(labelWithString: "正在运行的应用")
        countLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton = NSButton(title: "刷新", target: self, action: #selector(manualRefresh))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        pinButton = NSButton()
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "置顶")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        pinButton.isBordered = false
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.toolTip = "面板置顶（始终显示在最前）"
        pinButton.setAccessibilityLabel("面板置顶")
        pinButton.translatesAutoresizingMaskIntoConstraints = false

        authBanner = NSButton(
            title: "打开「系统设置 › 隐私与安全性 › 辅助功能」，勾选 CloseApps 以显示窗口列表 →",
            target: self,
            action: #selector(openAXSettings)
        )
        authBanner.font = .systemFont(ofSize: 11)
        authBanner.isBordered = false
        authBanner.contentTintColor = .systemOrange
        authBanner.alignment = .center
        authBanner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: defaultStatus)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        cardGrid = CardGridView(frame: .zero)
        cardGrid.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = cardGrid
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: "没有正在运行的应用")
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        content.addSubview(countLabel)
        content.addSubview(refreshButton)
        content.addSubview(pinButton)
        content.addSubview(authBanner)
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)
        content.addSubview(statusLabel)

        authBannerHeight = authBanner.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),

            refreshButton.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            pinButton.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -10),
            pinButton.widthAnchor.constraint(equalToConstant: 26),
            pinButton.heightAnchor.constraint(equalToConstant: 24),

            authBanner.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 4),
            authBanner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            authBanner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            authBannerHeight,

            scrollView.topAnchor.constraint(equalTo: authBanner.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            cardGrid.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            cardGrid.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 数据

    private var visibleApps: [NSRunningApplication] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != myPid
        }
    }

    func reload(force: Bool = false) {
        reloadCounter += 1
        let trusted = axTrusted()
        authBanner.isHidden = trusted
        authBannerHeight.isActive = !trusted
        authBannerHeight.constant = trusted ? 0 : 18
        if !trusted { authBannerHeight.constant = 18 }

        let current = visibleApps.sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
        var windowsByPid: [pid_t: [WinInfo]] = [:]
        if trusted {
            for app in current {
                // 过滤无标题的隐藏窗口，只有真实可见窗口才计
                windowsByPid[app.processIdentifier] = axWindows(for: app).filter { !$0.title.isEmpty }
            }
        }

        // 签名：进程集合 + 窗口数量；数量没变时跳过重建（每 10 秒强制重建一次以刷新标题）
        let signature = current.map { "\($0.processIdentifier)|\(windowsByPid[$0.processIdentifier]?.count ?? 0)" }
        let periodic = reloadCounter % 5 == 0
        if !force && !periodic && signature == lastSignature { return }
        lastSignature = signature
        apps = current

        countLabel.stringValue = "正在运行的应用（\(apps.count)）"
        // 扁平卡片流：应用卡在前，其窗口卡紧随其后（仅显示 ≥2 个窗口的应用，
        // 0/1 个窗口时应用卡已覆盖该窗口，不再额外显示）
        var cards: [NSView] = []
        for app in apps {
            let wins = windowsByPid[app.processIdentifier] ?? []
            cards.append(AppCardView(app: app, windowsCount: wins.count, panel: self))
            if wins.count >= 2 {
                for win in wins { cards.append(WindowCardView(win: win, app: app, panel: self)) }
            }
        }
        cardGrid.setCards(cards)
        emptyLabel.isHidden = !apps.isEmpty
    }

    // MARK: 关闭应用（整个进程树）

    func forceClose(_ app: NSRunningApplication, card: AppCardView? = nil) {
        let name = app.localizedName ?? "未知应用"
        let pid = app.processIdentifier
        let bundlePath = app.bundleURL?.path
        card?.markClosing()
        setStatus("正在彻底关闭「\(name)」…")

        // 立刻记下整个进程树（后代 + 同 bundle 路径进程），保证辅助进程也被清理
        let tree = collectProcessTree(rootPid: pid, bundlePath: bundlePath)
        if !app.terminate() {
            kill(pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            if !app.isTerminated {
                killTreeIfAlive(tree)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.reload(force: true)
                self.setStatus(app.isTerminated ? "✓ 已彻底关闭「\(name)」(含 \(tree.count) 个进程)" : "✗ 未能关闭「\(name)」")
            }
        }
    }

    // MARK: 面板置顶

    @objc private func togglePin() {
        setPinned(!isPinned)
    }

    private func setPinned(_ pinned: Bool, silent: Bool = false) {
        isPinned = pinned
        window.level = pinned ? .floating : .normal
        UserDefaults.standard.set(pinned, forKey: pinKey)
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "置顶")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = pinned ? "取消置顶" : "面板置顶（始终显示在最前）"
        if !silent {
            setStatus(pinned ? "✓ 面板已置顶" : "已取消置顶")
        }
    }

    // MARK: 其他操作

    @objc private func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func manualRefresh() {
        reload(force: true)
        setStatus("已刷新")
    }

    private func setStatus(_ text: String) {
        statusResetItem?.cancel()
        statusLabel.stringValue = text
        let item = DispatchWorkItem { [weak self] in
            self?.statusLabel.stringValue = self?.defaultStatus ?? ""
        }
        statusResetItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }
}

let app = NSApplication.shared
let controller = AppDelegate()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
