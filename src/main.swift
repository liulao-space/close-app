import AppKit

// MARK: - 卡片网格容器（手动流式布局，自动按窗口宽度分列）

final class CardGridView: NSView {
    static let cardSize = NSSize(width: 120, height: 104)
    static let hSpacing: CGFloat = 12
    static let vSpacing: CGFloat = 12
    static let padding: CGFloat = 10

    private(set) var cards: [AppCardView] = []

    override var isFlipped: Bool { true }

    func setCards(_ newCards: [AppCardView]) {
        cards.forEach { $0.removeFromSuperview() }
        cards = newCards
        cards.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let contentWidth = bounds.width
        let availWidth = max(contentWidth - 2 * Self.padding, 0)
        var columns = Int((availWidth + Self.hSpacing) / (Self.cardSize.width + Self.hSpacing))
        columns = max(columns, 1)
        let gridWidth = CGFloat(columns) * Self.cardSize.width + CGFloat(columns - 1) * Self.hSpacing
        let startX = (contentWidth - gridWidth) / 2

        for (index, card) in cards.enumerated() {
            let column = index % columns
            let row = index / columns
            card.frame = NSRect(
                x: startX + CGFloat(column) * (Self.cardSize.width + Self.hSpacing),
                y: Self.padding + CGFloat(row) * (Self.cardSize.height + Self.vSpacing),
                width: Self.cardSize.width,
                height: Self.cardSize.height
            )
        }

        let rows = max((cards.count + columns - 1) / columns, 1)
        let newHeight = Self.padding * 2 + CGFloat(rows) * Self.cardSize.height + CGFloat(rows - 1) * Self.vSpacing
        if abs(frame.height - newHeight) > 0.5 {
            frame.size = NSSize(width: frame.width, height: newHeight)
        }
    }
}

// MARK: - 单张应用卡片（系统原生振动材质，悬停时呈现"强调"高亮）

final class AppCardView: NSVisualEffectView {
    let app: NSRunningApplication
    private weak var panel: AppDelegate?

    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isClosing = false

    init(app: NSRunningApplication, panel: AppDelegate) {
        self.app = app
        self.panel = panel
        super.init(frame: .zero)

        // 通知中心小组件同款材质：半透明，悬停时切换为强调外观
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let name = app.localizedName ?? "未知应用"
        toolTip = "点击激活「\(name)」，点右上角 ✕ 彻底关闭"

        let iconView = NSImageView(image: app.icon ?? NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let pidLabel = NSTextField(labelWithString: "PID \(app.processIdentifier)")
        pidLabel.font = .systemFont(ofSize: 10)
        pidLabel.textColor = .secondaryLabelColor
        pidLabel.alignment = .center
        pidLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "彻底关闭"
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
            pidLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pidLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

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
        isEmphasized = isHovering
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
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isClosing else { return }
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

// MARK: - 面板控制器

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var cardGrid: CardGridView!
    private var emptyLabel: NSTextField!
    private var countLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!

    private var apps: [NSRunningApplication] = []
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusResetItem: DispatchWorkItem?

    private let defaultStatus = "点击卡片右上角的 ✕ 彻底关闭应用；点击卡片本身可激活该应用"

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "应用关闭面板"
        win.minSize = NSSize(width: 300, height: 420)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.center()
        window = win

        // 整个面板的毛玻璃底板（透出桌面/背后窗口，随亮暗模式自适应）
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 460, height: 620))
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

        statusLabel = NSTextField(labelWithString: defaultStatus)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        cardGrid = CardGridView(frame: NSRect(x: 0, y: 0, width: 428, height: 100))
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
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),

            refreshButton.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            scrollView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            cardGrid.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

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

    private func reload(force: Bool = false) {
        let current = visibleApps.sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
        if !force, current.map({ $0.processIdentifier }) == apps.map({ $0.processIdentifier }) { return }
        apps = current
        countLabel.stringValue = "正在运行的应用（\(apps.count)）"
        cardGrid.setCards(apps.map { AppCardView(app: $0, panel: self) })
        emptyLabel.isHidden = !apps.isEmpty
    }

    // MARK: 关闭应用

    func forceClose(_ app: NSRunningApplication, card: AppCardView? = nil) {
        let name = app.localizedName ?? "未知应用"
        let pid = app.processIdentifier
        card?.markClosing()
        setStatus("正在关闭「\(name)」…")

        // 先礼貌退出；2.5 秒后仍存活则 SIGKILL，保证"彻底关闭"
        if !app.terminate() {
            kill(pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            if !app.isTerminated {
                kill(pid, SIGKILL)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.reload(force: true)
                self.setStatus(app.isTerminated ? "✓ 已彻底关闭「\(name)」" : "✗ 未能关闭「\(name)」")
            }
        }
    }

    // MARK: 其他操作

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
