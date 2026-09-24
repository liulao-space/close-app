import AppKit
import ApplicationServices
import Carbon
import Darwin
import ServiceManagement
import Sparkle

// MARK: - 常量

private enum Cfg {
    /// 折叠态的宽度（高度随屏幕定：无刘海屏 = 菜单栏高，做成"假刘海"）
    static let capsuleWidth: CGFloat = 176
    /// 初始/兜底尺寸（真正的尺寸由 islandFrame 按屏幕算）
    static let capsuleSize = NSSize(width: 176, height: 36)
    /// 折叠态下缘两角的圆角半径（上缘是直角）—— 就是 CSS 的 `border-radius: 0 0 16px 16px`。
    /// **折叠态只要看得见，一律是这个形状**：无刘海屏那枚"假刘海"贴屏幕顶沿；
    /// 有刘海屏关掉「折叠时藏进刘海」时那枚胶囊吊在刘海正下方，上缘直角正好跟刘海接上。
    static let fakeNotchRadius: CGFloat = 16
    /// 折叠态藏进刘海时，往刘海下方多留这么一点做悬停容错。
    /// 刘海是物理盲区（摄像头模组挡着，那块屏幕不显示内容），面板整体又是透明的，
    /// 所以多出来的这一条不会显形，只是让鼠标更容易扫到。
    static let notchHoverMargin: CGFloat = 12
    /// 展开态面板
    static let expandedSize = NSSize(width: 596, height: 620)
    static let headerHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 18
    /// 展开/收起的弹簧响应时间（大约走完要这么久）。0.30s 是「看得见过程但不拖沓」的长度：
    /// 再短就成「啪」地一下，再长会让人觉得面板在慢慢地爬。
    static let expandResponse: TimeInterval = 0.26
    static let collapseResponse: TimeInterval = 0.18
    /// 弹簧阻尼比。略小于 1 → 末端轻轻过冲约 1.5% 再收住，这就是「丝滑」和「生硬」的分界；
    /// 等于 1 是临界阻尼（不过冲，但收尾发闷），大于 1 会拖泥带水。
    static let morphDamping: Double = 0.78
    /// 拖动时面板离屏幕边缘至少留这么远，拖不丢
    static let dragEdgeMargin: CGFloat = 8
    /// 鼠标移开后多久收起
    static let collapseDelay: TimeInterval = 0.45
    /// 展开态检查鼠标真实位置的间隔（收起与否只看坐标，不看控件的进出事件）
    static let hoverPollInterval: TimeInterval = 0.06
    /// 收起时鼠标还赖在命中区里 → 先不忙重开，等它挪开；这是最长等待兜底
    static let reopenGuardFallback: TimeInterval = 1.5
    static let refreshInterval: TimeInterval = 2.0
    /// 检查更新：一个只读的 HTTPS GET，拉 GitHub 上公开的 latest release。
    /// **不用上架、不用开发者账号、不用任何系统授权**，也不往上报任何本机信息 ——
    /// 就是个普通网络请求，跟"系统推送通知"完全是两码事。
    static let updateFeedURL = "https://api.github.com/repos/liulao-space/close-app/releases/latest"
    static let releasePageURL = "https://github.com/liulao-space/close-app/releases"
    /// 启动后先忙正事，过一会儿再查；之后每 6 小时一次
    static let updateCheckDelay: TimeInterval = 6
    static let updateCheckInterval: TimeInterval = 6 * 3600
    static var detailSize: NSSize {
        NSSize(width: expandedSize.width, height: expandedSize.height - headerHeight)
    }
}

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

// MARK: - 跨桌面取窗口（本项目唯一用到私有 API 的地方）

/// ⚠️ 下面两个是 CloseApps 用到的**唯一两个私有 API**，只为了一件事：**把藏在别的桌面上的窗口捞出来**。
///
/// 公开 API 做不到，这是实测出来的边界（2026-09-24，两条轴分别对照过）：
///   · `kAXWindows` **只返回「当前正在显示的那个桌面」上的窗口**。Chromium 系（VSCode / Chrome /
///     一切 Electron）尤其严格：窗口不在当前桌面时它返回**空数组**，连窗口标题都拿不到。
///   · **换屏不影响**：一个窗口在主屏、一个在外接屏（两块屏都能看见）时，两个都列得出来。
///   · **应用是不是前台不影响**。真正的开关是「这个窗口所在的桌面当前有没有被显示」。
///     所以你在一块屏顶部唤出面板时，另一块屏"别的桌面"里的窗口，面板一个都看不见 ——
///     这就是「两个窗口只显示一个」的来源。
///   · **最小化不影响**（最小化的窗口照样列出来）。
///
/// 两条补救路径（做法与开源项目 alt-tab-macos 一致，它靠这套在多显示器 + 多桌面上列全窗口）：
///   ① `kAXFocusedWindow` / `kAXMainWindow`：AppKit **没有**把这两个属性挂到"仅当前桌面"的过滤上，
///      所以窗口在别的桌面时，它俩是唯一还肯交出东西的入口 —— 而且是同一次 IPC，不额外花时间。
///   ② `_AXUIElementCreateWithRemoteToken` + 枚举元素 ID：用「pid + magic + 元素 ID」拼一个远程令牌，
///      挨个 ID 去试，就能拿到 `kAXWindows` 之外的窗口元素（跨桌面窗口、非活动标签页都在此列）。
///      这是唯一途径。代价是要扫 ID（实测 ~11µs/个），所以**只在面板展开时、后台低优先级地扫**。
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// 从 AX 元素反查它的 CGWindowID —— 用来跨来源去重、以及跟系统窗口列表对齐。
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

private func axValue(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success else { return nil }
    return v
}

private func axText(_ e: AXUIElement, _ key: String) -> String {
    (axValue(e, key) as? String) ?? ""
}

private func axWindowID(_ e: AXUIElement) -> CGWindowID? {
    var w = CGWindowID(0)
    guard _AXUIElementGetWindow(e, &w) == .success, w != 0 else { return nil }
    return w
}

/// 判定「这是个真窗口」。要筛掉的是两类假货：
///   ① `kAXWindows` 里混进来的代理元素（访达实测有一个 subrole 为空、没有关闭按钮的条目）
///   ② 系统窗口列表里的隐藏辅助窗（Chrome 的 1930×139、微信的 635×892，都是 AXUnknown 且没有关闭按钮）
/// 判据取「标准窗口子角色 **或** 带关闭按钮」—— 实测 6 个应用、9 个窗口全部吻合，没有误伤。
private func axIsRealWindow(_ e: AXUIElement) -> Bool {
    guard axText(e, kAXRoleAttribute as String) == "AXWindow" else { return false }
    if axText(e, kAXSubroleAttribute as String) == "AXStandardWindow" { return true }
    return axValue(e, kAXCloseButtonAttribute as String) != nil
}

/// 窗口元素上有没有关闭按钮 —— 比 `axIsRealWindow` 更严一档。
/// 用来区分「读不到标题的真窗口」（微信那个 700×640：三个按钮齐全）和
/// 「读不到标题的假货」（同应用的 635×892：sub=AXUnknown、一个按钮都没有）。
private func axHasCloseButton(_ e: AXUIElement) -> Bool {
    axValue(e, kAXCloseButtonAttribute as String) != nil
}

/// 系统窗口列表里「像真窗口」的窗口 ID（层 0 + 尺寸不像工具条）。
/// 条件故意放得很松：它只用来判断"是不是还有窗口没被 AX 交出来"，
/// 多报几个 ID 的代价只是多试几次，真正的把关在 `axIsRealWindow`。
private func cgCandidateWindowIDs() -> [pid_t: Set<CGWindowID>] {
    var map: [pid_t: Set<CGWindowID>] = [:]
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
        return map
    }
    for w in list {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let box = w[kCGWindowBounds as String] as? [String: Any],
              let sw = box["Width"] as? Double, let sh = box["Height"] as? Double,
              sw >= 200, sh >= 120,
              let num = w[kCGWindowNumber as String] as? Int else { continue }
        map[pid, default: []].insert(CGWindowID(num))
    }
    return map
}

private struct BruteForceResult {
    var elements: [AXUIElement] = []
    var scanned = 0
    var elapsedMs: Double = 0
    var remaining: Set<CGWindowID> = []
    /// 本轮见到的**最大有效元素 ID** —— 用来判断扫描上界要不要往外扩。
    var maxValidID: UInt64 = 0
}

/// 暴力枚举一个进程的元素 ID，把 `wanted` 里那些窗口的 AX 元素找出来。
/// ⚠️ 必须在**后台线程**跑（会占住调用线程几十毫秒）。跨进程的 AX 调用不要求主线程。
///
/// ★★ 扫描上界必须按**固定值**（`ceilID`）扫，**绝对不要**改成"连续 N 个 ID 取不到元素就停"。
/// 踩过的坑：元素 ID 空间里存在**很大的空洞**。实测微信 20 个有效元素分布在 46~706，
/// 其中 `333 → 703` 之间就空了 **370** 个 ID；当时用"连续 300 落空即停"，扫到 334 就收工，
/// 把 703/704/706 三个元素整个漏掉 —— 而 703 正是用户要看的那扇窗口
/// （700×640、subrole=AXStandardWindow），表现就是"窗口明明开着，面板不显示"。
/// 按 3000 的上界扫只要 41ms（13.8µs/个 ID），快且不会漏；真遇到元素特别多的应用，
/// 由 `hiddenWindowElements` 里的"顶到边界就翻倍"逻辑自动外扩。
private func bruteForceWindowElements(pid: pid_t, wanted: Set<CGWindowID>,
                                      ceilID: UInt64, budgetMs: Double) -> BruteForceResult {
    var result = BruteForceResult(remaining: wanted)
    guard !wanted.isEmpty, let token = CFDataCreateMutable(kCFAllocatorDefault, 20) else { return result }
    CFDataSetLength(token, 20)
    guard let bytes = CFDataGetMutableBytePtr(token) else { return result }
    // 20 字节令牌：pid(4) + 0(4) + magic "coco"(4) + 元素 ID(8)，字节序不能错
    memset(bytes, 0, 20)
    var pidField = pid
    memcpy(bytes, &pidField, 4)
    var magic = Int32(0x636f636f)
    memcpy(bytes + 8, &magic, 4)

    let started = CACurrentMediaTime()
    let deadline = started + budgetMs / 1000
    var id: UInt64 = 0
    while id < ceilID, CACurrentMediaTime() < deadline {
        var idField = id
        memcpy(bytes + 12, &idField, 8)
        result.scanned += 1
        if let e = _AXUIElementCreateWithRemoteToken(token)?.takeRetainedValue(),
           let w = axWindowID(e) {
            result.maxValidID = max(result.maxValidID, id)
            if result.remaining.contains(w), axIsRealWindow(e) {
                result.elements.append(e)
                result.remaining.remove(w)
                if result.remaining.isEmpty { break }
            }
        }
        id += 1
    }
    result.elapsedMs = (CACurrentMediaTime() - started) * 1000
    return result
}

/// 面板展开时才扫（收起时不做无谓的 IPC 扫描）。由 PanelController 在 expand/collapse 里维护。
private var panelIsExpandedForScan = false
/// 扫描结果缓存：pid → (扫完的时刻, 已捞到的窗口元素, 本轮用的扫描上界)。
/// TTL 内直接用，避免每 2 秒重扫一遍。
private var hiddenWindowCache: [pid_t: (stamp: TimeInterval, elements: [CGWindowID: AXUIElement], ceil: UInt64)] = [:]
private var hiddenScanInFlight: Set<pid_t> = []
/// 单次扫描的**防呆上限**（正常用不到 —— 3000 个 ID 实测只要 41ms）。
private let hiddenScanBudgetMs: Double = 1500
/// 元素 ID 的扫描上界起点。实测微信的元素 ID 空间只到 706（20 个有效元素、最大空洞 370 个 ID）。
private let hiddenScanStartCeil: UInt64 = 3000
/// 元素 ID 的绝对上限：某轮发现有效元素顶到了上界附近 → 上界翻倍（最多翻到这里）。
private let hiddenScanMaxCeil: UInt64 = 48000
/// 「顶到边界」的判定余量：本轮最大有效 ID 离上界比这还近，就认为元素空间没扫完。
private let hiddenScanEdgeSlack: UInt64 = 500
/// 扫描结果的保鲜期。**过期只是"该重扫了"，绝不影响继续使用旧结果**（见 hiddenWindowElements）。
private let hiddenCacheTTL: TimeInterval = 3
/// 跨桌面扫描完成后的回调（由 PanelController 在 `expand()` 里挂上）。有了它，
/// 捞回来的窗口**当轮就能上屏**，不用等下一个 2 秒刷新 tick ——
/// 否则表现就是"面板刚打开时少一个窗口，过两秒自己冒出来"。
private var hiddenScanDidFinish: (() -> Void)?

/// 清掉已经不在运行的应用留下的缓存（长期挂着不清理会越攒越多）
private func pruneHiddenWindowCache(keeping pids: Set<pid_t>) {
    hiddenWindowCache = hiddenWindowCache.filter { pids.contains($0.key) }
}

/// 顶层作用域里 `PanelController.dbg`（私有方法）够不着，跨桌面扫描这条线单独走一个。
private let scanDebugEnabled = ProcessInfo.processInfo.environment["CLOSEAPPS_DEBUG"] == "1"
private func dbgScan(_ message: String) {
    guard scanDebugEnabled else { return }
    FileHandle.standardError.write(Data(("[closeapps] " + message + "\n").utf8))
}

/// 拿「藏在别的桌面上的窗口」元素。
///
/// ⚠️⚠️ 这段是**纠错过一次**的，动它之前先读完：
///
/// 旧写法在「缓存过期」那一轮直接 `return []`，要等后台扫完、再等下一轮刷新才补上。
/// 而 TTL(6s) 是刷新间隔(2s)的整数倍 → **面板每 6 秒必然"掉一次窗口卡"**，下一轮再长回来。
/// 用户看到的就是「微信明明两个窗口，有时候显示两个、有时候只显示一个」。
///
/// 现在的语义是 **stale-while-revalidate**：旧结果一直用，只有拿到新结果才替换。
/// 任何时候都不会因为"正在后台刷新"而少给窗口。
///
/// 另：缓存里存的元素可能已经被关掉了 / 窗口重建换了 CGWindowID，所以**仍然按
/// `missing` 校验**（不在缺席名单里的不返回，免得和 `kAXWindows` 已经给出的重复）。
private func hiddenWindowElements(pid: pid_t, missing: Set<CGWindowID>) -> [AXUIElement] {
    guard !missing.isEmpty else { return [] }
    let now = CACurrentMediaTime()
    let cached = hiddenWindowCache[pid]
    let isFresh = cached.map { now - $0.stamp < hiddenCacheTTL } ?? false
    if !isFresh, panelIsExpandedForScan, !hiddenScanInFlight.contains(pid) {
        hiddenScanInFlight.insert(pid)
        let ceilBefore = cached?.ceil ?? hiddenScanStartCeil
        DispatchQueue.global(qos: .utility).async {
            let r = bruteForceWindowElements(pid: pid, wanted: missing, ceilID: ceilBefore,
                                             budgetMs: hiddenScanBudgetMs)
            DispatchQueue.main.async {
                hiddenScanInFlight.remove(pid)
                // 每轮都从 0 扫到上界（= 元素全集）→ 整份替换，
                // 顺手清掉已关闭窗口留在缓存里的陈旧元素
                var fresh: [CGWindowID: AXUIElement] = [:]
                for e in r.elements {
                    if let w = axWindowID(e) { fresh[w] = e }
                }
                // 有效元素顶到了上界附近 → 这应用的元素空间比当前上界大，翻倍续扫
                var nextCeil = ceilBefore
                if r.maxValidID + hiddenScanEdgeSlack >= ceilBefore, ceilBefore < hiddenScanMaxCeil {
                    nextCeil = min(hiddenScanMaxCeil, ceilBefore * 2)
                    dbgScan("hidden: 「pid \(pid)」元素 ID 顶到 \(r.maxValidID)（上界 \(ceilBefore)）→ 上界扩到 \(nextCeil)")
                }
                hiddenWindowCache[pid] = (CACurrentMediaTime(), fresh, nextCeil)
                // 当轮就刷：不然新捞到的窗口要等下一个 2 秒 tick 才上屏
                hiddenScanDidFinish?()
            }
        }
    }
    // ★ 返回缓存里的**全部**元素，**不按 `missing` 过滤**。
    // 原因：CGWindowID 会变 —— 实测微信同一个 700×640 的窗口，先后来过 336 和 26670。
    // 按 ID 过滤的话，窗口每次重建都会让缓存里的它"凭空消失一轮再长回来"，又是一次抖动。
    // 重复的问题由 `axWindows` 里按 CGWindowID 去重兜住（`kAXWindows` 交出来的排在前面、
    // 优先保留）；元素失效（窗口已关）则由"标题为空"那条过滤兜住。
    return cached.map { Array($0.elements.values) } ?? []
}

private func axWindows(for app: NSRunningApplication, cgCandidates: Set<CGWindowID> = []) -> [WinInfo] {
    let appRef = AXUIElementCreateApplication(app.processIdentifier)
    // ⚠️⚠️ 这一行是必须的：AX 的**默认消息超时是 6 秒**，而 `reload()` 是在**主线程**上
    // 挨个应用同步查窗口的 —— 只要有一个应用那一瞬间不响应（实测「活动监视器」1155ms，
    // 最坏一次把整次 reload 拖到 **6822ms**），面板就是**真的卡住**：动画走完了，
    // 但内容不刷新、点不动，用户只会觉得"这软件卡了"。
    // 卡一个上限之后，不响应的应用会**快速失败**（返回错误 → 当作没有窗口），
    // 代价只是这一个应用暂时不展开窗口卡，换来面板永远秒开。
    AXUIElementSetMessagingTimeout(appRef, 0.3)

    // 一次 IPC 把三个属性一起取回来（分开取是三次 IPC，白白多花两倍时间）：
    //   [0] kAXWindows        —— 只含当前显示的桌面上的窗口
    //   [1] kAXFocusedWindow  —— AppKit 没把这两个挂到"仅当前桌面"的过滤上，
    //   [2] kAXMainWindow        窗口藏在别的桌面时，靠它俩还能捞回主窗口/焦点窗口
    var elements: [AXUIElement] = []
    var values: CFArray?
    let keys = [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute] as CFArray
    if AXUIElementCopyMultipleAttributeValues(appRef, keys, [], &values) == .success,
       let list = values as? [CFTypeRef] {
        for (index, raw) in list.enumerated() {
            // 属性取不到时给的是 .axError 占位值，不是元素 —— 不能当成元素往下用
            if CFGetTypeID(raw) == AXValueGetTypeID(),
               AXValueGetType(unsafeBitCast(raw, to: AXValue.self)) == .axError { continue }
            if CFGetTypeID(raw) == CFArrayGetTypeID(), let windows = raw as? [AXUIElement] {
                elements.append(contentsOf: windows)
            } else if CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let one = unsafeBitCast(raw, to: AXUIElement.self)
                // focused / main 这两个位上的元素必须先过"真窗口"判定（可能是个 sheet/对话框）
                if index > 0, axIsRealWindow(one) { elements.append(one) }
            }
        }
    }

    // 跨来源去重（同一个窗口可能同时出现在多个属性里）；
    // 拿不到 CGWindowID 的没法比对，原样留着不去重，宁可重复也不漏
    var seen = Set<CGWindowID>()
    var unique: [AXUIElement] = []
    for e in elements {
        if let wid = axWindowID(e), !seen.insert(wid).inserted { continue }
        unique.append(e)
    }

    // 还有窗口没露面（在别的桌面上）→ 捞。捞回来的单独记一份 ID，
    // 下面的标题过滤要对它们网开一面（见注释）
    var recoveredIDs = Set<CGWindowID>()
    if !cgCandidates.isEmpty {
        let known = Set(unique.compactMap { axWindowID($0) })
        for e in hiddenWindowElements(pid: app.processIdentifier,
                                      missing: cgCandidates.subtracting(known)) {
            if let wid = axWindowID(e) { recoveredIDs.insert(wid) }
            unique.append(e)
        }
    }

    var result: [WinInfo] = []
    for w in unique {
        var title = axText(w, kAXTitleAttribute as String)
        if title.isEmpty {
            // ⚠️ 别退回"空标题一律丢掉"。跨桌面捞回来的窗口里存在**真窗口但读不到标题**：
            // 实测微信有个 700×640 的窗口 —— AXSubrole=AXStandardWindow、关闭/最小化/全屏
            // 三个按钮齐全、AXPosition/AXSize 都正常、AXRaise 能让它现身（onscreen 由 false 变 true），
            // 就是 AXTitle 空。丢掉的后果正是用户报的「明明开了两个窗口，面板只显示一个」。
            //
            // 宽容只给这条路（`kAXWindows` 自己交出来的空标题条目基本都是隐藏辅助窗，
            // Chrome 的 1930×139 那种，那条路继续严格），并且两条判据必须同时满足：
            //   · subrole == AXStandardWindow —— 挡掉 `AXDialog`（实测 Tailscale 那个
            //     1107×887 的 783，它也会被捞回来且有关闭按钮）和 `AXUnknown`
            //     （实测微信那个 635×892 的 329，是假货）
            //   · 窗口上有关闭按钮 —— 元素完整的旁证
            guard let wid = axWindowID(w), recoveredIDs.contains(wid),
                  axText(w, kAXSubroleAttribute as String) == "AXStandardWindow",
                  axHasCloseButton(w) else { continue }
            title = "未命名窗口"
        }
        let minimized = (axValue(w, kAXMinimizedAttribute as String) as? Bool) ?? false
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

/// 把一个**具体窗口**带到用户眼前（点窗口卡走的就是这条路）。
///
/// ⚠️ 只调 `AXUIElementPerformAction(win, kAXRaiseAction)` 是**不够**的，这是个真踩过的坑：
/// 实测它对微信返回 `success`、`kAXMainAttribute` 也**确实**从 false 翻成了 true，
/// **但前台应用纹丝不动** —— 因为 AXRaise 只在**应用内部**调整窗口次序，
/// **不会激活应用本身**。应用还压在别的窗口后面时，它的窗口在"应用内部排第一"
/// 依然在屏幕后面，用户看到的就是"点了完全没反应"。
/// 所以顺序必须是：**先把应用整个提到前台（跟应用卡同一套），再选窗口**。
///
/// - Parameter reRaiseAfter: 激活是异步的，而且系统在激活一个应用时会把该应用**上次**的
///   主窗口恢复回来，有可能把刚抬起来的这个顶掉；隔一小会儿再抬一次兜底。
///   这时面板已经收起，用户看不到任何抖动。传 0 关闭（调试用）。
private func bringWindowForward(app: NSRunningApplication, win: WinInfo, reRaiseAfter: TimeInterval = 0.35) {
    if let bundleURL = app.bundleURL {
        NSWorkspace.shared.open(bundleURL)
    }
    if #available(macOS 14.0, *) {
        app.activate(from: .current)
    } else {
        app.activate(options: [.activateIgnoringOtherApps])
    }
    // 最小化的窗口：AXRaise 能顺带把它还原（微信实测 min T→F），但不是每个应用都认这套，
    // 最小化时显式取消一次更稳（对没最小化的窗口设成 false 本身是无害的）。
    if win.minimized {
        AXUIElementSetAttributeValue(win.ref, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    win.raise()
    guard reRaiseAfter > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + reRaiseAfter) {
        win.raise()
    }
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
            ? "「\(name)」(PID \(app.processIdentifier)) 有 \(windowsCount) 个窗口 · 点 ✕ 彻底关闭整个应用 · 点卡片激活"
            : "点击激活「\(name)」(PID \(app.processIdentifier))，点右上角 ✕ 彻底关闭整个应用"

        let iconView = NSImageView(image: app.icon ?? NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // 副标题负责回答"这张卡是什么"：应用卡必须一眼看出是**整个应用**（总开关），
        // 不是某个窗口。⚠️ 面板里应用卡和窗口卡是同尺寸同底色的兄弟，光靠位置分不开 ——
        // 之前这里写的是 `PID 500 · 2 窗口`，结果"微信主窗口"的标题恰好也叫「微信」，
        // 用户数出"三个微信"（实际是 1 张应用卡 + 2 张窗口卡，数据没错，是长得太像）。
        // PID 挪去 toolTip 了 —— 120pt 宽的卡片塞不下"整个应用"和 PID 两件事。
        let pidText = windowsCount > 1 ? "整个应用 · \(windowsCount) 个窗口" : "整个应用"
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

    /// 面板不是 key window 时，第一次点击也要立刻生效
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refreshAppearance() {
        guard let layer else { return }
        layer.backgroundColor = (isHovering ? NSColor.controlAccentColor : NSColor.white)
            .withAlphaComponent(isHovering ? 0.18 : 0.10).cgColor
        layer.cornerRadius = 10
        // ★ 应用卡描边用 accent 色（窗口卡是普通分隔线色）—— 这是"一眼可分"的第一个信号。
        // 前提是**应用卡和窗口卡是同尺寸同底色的兄弟**，光靠位置和 9pt 副标题分不开，
        // 用户会把一张应用卡 + 两张窗口卡数成"三个微信"。第二个信号是副标题「整个应用」，
        // 两个互为冗余：任一没看清，另一个还认得出。
        layer.borderWidth = 1.5
        layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(isHovering ? 0.85 : 0.45).cgColor
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
        // 打开 bundle 等同于点击 Dock 图标：自动切换到该应用所在的桌面并前置。
        //
        // ⚠️ 必须带 `.activateAllWindows`：这个应用的窗口可能散在**别的桌面**上，
        // 而 Chromium 系应用（VSCode / Chrome / 一切 Electron）**只把当前桌面的窗口
        // 交给辅助功能接口** —— 窗口不叫过来，面板下次刷新照样看不到它们
        // （实测：VSCode 两窗口在外接屏桌面时，面板在另一块屏只能拿到 0 个窗口）。
        // 带上这个选项，点一下应用卡就把它的所有窗口（含别的桌面、含最小化的）都带过来。
        if let bundleURL = app.bundleURL {
            NSWorkspace.shared.open(bundleURL)
        }
        if #available(macOS 14.0, *) {
            app.activate(from: .current, options: [.activateAllWindows])
        } else {
            app.activate(options: [.activateAllWindows])
        }
        // 目的已达成（切到别的应用去了），面板跟着收起
        panel?.collapseAfterActivating(appName: app.localizedName ?? "应用")
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

        // 副标题不再重复应用名（紧邻的应用卡已经写了，同图标也在，重复就是噪音）。
        // 这里只回答"这张卡是一个窗口"，和上面「整个应用」形成对照 —— 合起来才拼出层级：
        // 应用卡（accent 描边 + 整个应用）→ 下面跟它的一排窗口卡。
        let statusLabel = NSTextField(labelWithString: "窗口 · \(win.minimized ? "已最小化" : "点击打开")")
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

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

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

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        // 前置这个具体窗口（最小化的自动还原）——里面已经把"激活应用"这一步补上了，
        // 光 AXRaise 应用还在后台时用户什么都看不见
        bringWindowForward(app: app, win: win)
        panel?.collapseAfterActivating(appName: app.localizedName ?? "应用")
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
        invalidateContentSize()
    }

    private func invalidateContentSize() {
        invalidateIntrinsicContentSize()
    }
}

// MARK: - 全局快捷键（Carbon RegisterEventHotKey：公开 API，不需要辅助功能/输入监控权限）

private var gHotKeyManager: HotKeyManager?

final class HotKeyManager {
    static let signature: OSType = 0x434C4150 // 'CLAP'

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

    init() {
        gHotKeyManager = self
        installHandler()
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { gHotKeyManager?.onTrigger?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        guard keyCode != 0, modifiers != 0 else { return false }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

// MARK: - 快捷键录制控件（点击后按下组合键即可改键）

final class HotKeyRecorder: NSView {
    var onClick: (() -> Void)?
    var onCapture: ((UInt32, UInt32, String) -> Void)?
    var onCancel: (() -> Void)?

    private let textField = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    private(set) var isRecording = false {
        didSet { refresh() }
    }

    var label: String = "⌥⌘K" {
        didSet { refresh() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        textField.font = .systemFont(ofSize: 11, weight: .medium)
        textField.alignment = .center
        textField.lineBreakMode = .byClipping
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.centerXAnchor.constraint(equalTo: centerXAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
        toolTip = "点击后按下新的组合键改快捷键（Esc 取消 · Delete 清除）"
        setAccessibilityLabel("全局快捷键")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refresh() {
        guard let layer else { return }
        textField.stringValue = isRecording ? "按下组合键" : label
        textField.textColor = isRecording ? .controlAccentColor : (isHovering ? .labelColor : .secondaryLabelColor)
        layer.backgroundColor = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.white.withAlphaComponent(isHovering ? 0.16 : 0.08).cgColor
        layer.cornerRadius = 6
        layer.borderWidth = 1
        layer.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor)
            .withAlphaComponent(isRecording ? 0.9 : 0.7).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { isHovering = false; refresh() }

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else { return }
        onClick?()
    }

    func beginRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        onCancel?()
    }

    /// 控件里的标签不该吃掉点击：整块区域都归自己处理
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // Esc：取消
        if event.keyCode == 53 {
            isRecording = false
            onCancel?()
            return
        }
        // Delete / Backspace：清除快捷键
        if event.keyCode == 51 || event.keyCode == 117 {
            isRecording = false
            onCapture?(0, 0, "无")
            return
        }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let carbon = Self.carbonModifiers(flags)
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        let isFunctionKey = event.keyCode >= 96 && event.keyCode <= 133

        guard carbon != 0 || isFunctionKey else {
            NSSound.beep()
            return
        }
        let keyName = chars.isEmpty ? Self.functionKeyName(event.keyCode) : chars
        let newLabel = Self.modifierSymbols(flags) + keyName
        isRecording = false
        onCapture?(UInt32(event.keyCode), carbon, newLabel)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private static func functionKeyName(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 114: "Help", 115: "Home", 116: "PageUp", 117: "ForwardDelete",
            118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}

// MARK: - 开机启动（macOS 13+ 用 SMAppService；11/12 退回 LaunchAgent）

private enum LoginItem {
    static let label = "com.liulao.closeapps.launch"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var needsApproval: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .requiresApproval }
        return false
    }

    /// nil = 成功，否则为错误描述
    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if on {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>Label</key><string>\(label)</string>
            \t<key>ProgramArguments</key><array><string>\(exe)</string></array>
            \t<key>RunAtLoad</key><true/>
            \t<key>LimitLoadToSessionType</key><string>Aqua</string>
            </dict>
            </plist>
            """
            do {
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try plist.write(to: plistURL, atomically: true, encoding: .utf8)
                runLaunchctl(["load", "-w", plistURL.path])
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        runLaunchctl(["unload", "-w", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        return nil
    }

    private static func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - 灵动岛面板（无边框、不可激活、常驻所有桌面）

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 细一号的滚动条。宽度是**类方法**算出来的（NSScrollView 布局时问它），
/// 所以只能在子类里覆写 —— 给实例改 controlSize、改 frame 都会被重算回去。
/// 系统默认 15pt（传统样式）/ 11pt（浮动样式），这里统一给 8pt。
final class ThinScroller: NSScroller {
    static let width: CGFloat = 8
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { ThinScroller.width }
}

/// 内容视图：负责鼠标进出检测，并按窗口大小裁掉超出部分（折叠时只露出中间的胶囊）
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// 折叠态拖动：回调屏幕坐标增量（Cocoa 坐标，y 向上）
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragBegin: (() -> Void)?
    var onDragEnd: (() -> Void)?
    /// 判定"这一点是否归我来拖"（控制器按当前状态决定）。返回 false 就把事件交还子视图，
    /// 卡片、关闭按钮、录制控件照常工作。
    var shouldCaptureMouse: ((NSView, NSPoint) -> Bool)?

    private var trackingArea: NSTrackingArea?
    private var dragAnchor: NSPoint?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 拖动区得在命中测试这一层就抢过来：鼠标事件其实先落在最深的子视图上（图标、文字、毛玻璃层），
    /// 而 AppKit 之后只把 mouseDragged 送给"收到 mouseDown 的那个视图"——被 NSTextField 这类
    /// 控件吞掉就再也拖不动了。控制器用 shouldCaptureMouse 决定哪些点归拖动。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard let shouldCaptureMouse else { return hit }
        return shouldCaptureMouse(hit, convert(point, from: superview)) ? self : hit
    }

    // MARK: 拖动（接不接管由控制器的 shouldCaptureMouseForDrag 定：
    //              折叠态不接管；展开态只接管标题栏空白，按钮等控件一律让路）
    //
    // 不调 window.makeKey()：这是不可激活面板，抢 key 会把用户正在打字的那个窗口的
    // 焦点夺走。鼠标拖拽只要收到 mouseDown 的那个视图就能持续收 mouseDragged。

    override func mouseDown(with event: NSEvent) {
        dragAnchor = NSEvent.mouseLocation
        onDragBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let now = NSEvent.mouseLocation
        onDrag?(now.x - anchor.x, now.y - anchor.y)
        dragAnchor = now
    }

    override func mouseUp(with event: NSEvent) {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        onDragEnd?()
    }
}

private extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// 菜单栏高度（屏幕顶沿到菜单栏下沿）—— 无刘海屏上折叠条就做成这么高，才像一块真刘海
    var menuBarHeight: CGFloat { frame.maxY - visibleFrame.maxY }

    /// 刘海矩形（Cocoa 坐标）：屏幕顶部正中那块被摄像头模组物理挡住的区域。
    /// 没有刘海的屏幕返回 nil —— 那种屏上左右两块 auxiliaryTopArea 会拼满整宽。
    var notchRect: NSRect? {
        guard #available(macOS 12.0, *) else { return nil }
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let width = frame.width - left.width - right.width
        let height = safeAreaInsets.top
        guard width > 60, height > 0 else { return nil }
        return NSRect(x: frame.minX + left.width,
                      y: frame.maxY - height,
                      width: width,
                      height: height)
    }
}

/// 只有 CLOSEAPPS_DEBUG=1 才往 stderr 打点（和 AppDelegate.dbg 同一套开关）
private func morphLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["CLOSEAPPS_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[closeapps] " + message + "\n").utf8))
}

// MARK: - 动画（弹簧推进器）

/// 一个最小的弹簧积分器：每帧算出 0 → 1 的进度，落在目标上时自己停。
///
/// 为什么不用 `NSAnimationContext`：
/// ① 它只能吃一条固定时长的贝塞尔曲线，"起步迅速、末端极轻地过冲一下再收住"这种手感做不出来；
/// ② 它一次只管一组属性，frame 和内容想同步就得各开一组动画 —— 时长只要差一点，
///    看起来就是"面板先长完、内容再补上"，一眼假（上一版正是这么写的）。
///
/// 数值：半隐式欧拉，用真实 dt（夹在 [1/240, 1/30] 之间，某帧卡顿了也不会跳变），
/// 阻尼比 0.78 → 末端过冲约 2%，刚好是"活"而不是"弹"。
private final class SpringDriver {
    private let label: String            // 只用来打点（"展开"/"收起"）
    private let omega: Double            // 角频率：越大越快
    private let zeta: Double             // 阻尼比：1 = 临界阻尼（不过冲）
    private let onStep: (Double, Bool) -> Void
    private var timer: Timer?
    private var value: Double = 0        // 当前进度（可能略微超过 1）
    private var velocity: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var ticks = 0
    private var maxGap: Double = 0       // 最大一帧的间隔：这就是"卡不卡"的直接证据
    private var dropped = 0              // 间隔超过 2.5 个目标帧 = 这一帧被丢了
    private var frameInterval: Double = 1.0 / 60

    init(label: String, response: TimeInterval, damping: Double,
         onStep: @escaping (Double, Bool) -> Void) {
        self.label = label
        self.omega = 2 * Double.pi / max(0.06, response)
        self.zeta = damping
        self.onStep = onStep
    }

    /// 按屏幕刷新率起搏（60Hz 屏上不必白跑一倍），挂 `.common` 模式 ——
    /// 用户这会儿很可能正按着鼠标（run loop 处于 tracking 模式），只挂 default 会原地冻住。
    func start() {
        var fps = 60.0
        if #available(macOS 12.0, *) {
            for s in NSScreen.screens { fps = max(fps, Double(s.maximumFramesPerSecond)) }
        }
        let interval = 1.0 / min(max(fps, 60), 120)
        frameInterval = interval
        startedAt = CACurrentMediaTime()
        lastTick = startedAt
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard timer != nil else { return }
        let now = CACurrentMediaTime()
        let gap = now - lastTick
        maxGap = max(maxGap, gap)
        ticks += 1
        if gap > frameInterval * 2.5 { dropped += 1 }
        let dt = min(max(gap, 1.0 / 240.0), 1.0 / 30.0)
        lastTick = now
        // a = -2ζωv - ω²(x - 1)：标准弹簧 + 阻尼，目标点取 1
        velocity += (-2 * zeta * omega * velocity - omega * omega * (value - 1)) * dt
        value += velocity * dt
        if abs(value - 1) < 0.003 && abs(velocity) < 0.05 {
            cancel()
            morphLog("morph(\(label)) 完成: 帧数=\(ticks) 丢帧=\(dropped) "
                     + "用时=\(String(format: "%.2f", now - startedAt))s "
                     + "最大帧间隔=\(Int(maxGap * 1000))ms（目标 \(Int(frameInterval * 1000))ms）"
                     + (dropped > 2 ? " ← 卡顿偏多，动画看着会顿" : ""))
            onStep(1, true)     // 收尾：调用方把 frame 摆到精确的目标值
            return
        }
        onStep(value, false)
    }
}

// MARK: - 面板控制器

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 面板
    private var panel: IslandPanel!
    private var container: HoverView!
    private var blur: NSVisualEffectView!
    private var header: NSView!
    private var capsuleStack: NSStackView!
    private var capsuleBadge: NSView!
    private var capsuleLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var controlsStack: NSStackView!
    private var detail: NSView!
    private var scrollView: NSScrollView!
    private var cardGrid: CardGridView!
    private var emptyLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var authBanner: NSButton!
    private var authBannerHeight: NSLayoutConstraint!
    /// 查到新版本时，挂在授权横幅下面那一行细提示（没有新版就高度 0、完全不存在）
    private var updateBanner: NSButton!
    private var updateBannerHeight: NSLayoutConstraint!
    private var pinButton: NSButton!
    private var recorder: HotKeyRecorder!
    private var expandedOnly: [NSView] = []
    /// 头部高度约束（折叠成"假刘海"时要压到菜单栏那么高）
    private var headerHeightConstraint: NSLayoutConstraint!
    /// 展开态里"按住能拖面板"的视图（标题栏的空白与标题、胶囊内容）
    private var dragHandleViews: [NSView] = []

    // 菜单栏
    private var statusItem: NSStatusItem!

    // 状态
    private var isExpanded = false
    private var isPinned = false
    /// 调试用：让面板渲染时先丢掉最前面 N 个应用，只为导出"关掉几个之后"的演示素材。
    /// 纯渲染层的事，不会真的去关任何应用。
    private var debugAppDrop: Int = 0
    private var lastScreenID: UInt32 = 0
    private var screenWatchTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    /// 展开态：只看鼠标真实坐标决定收不收（控件进出事件在窗口动画期间会抖）
    private var hoverPollTimer: Timer?
    /// 展开那一刻的折叠命中区（刘海那一带算在里面）
    private var collapsedHitRect: NSRect = .zero
    /// 收起时鼠标还赖在命中区里 → 先不忙重开，等它挪开
    private var reopenBlocked = false
    private var reopenGuardWork: DispatchWorkItem?
    private var reopenWatchTimer: Timer?
    /// 拖动中
    private var isDraggingIsland = false
    /// 本次拖动累计移动了多少（用来区分"真拖动"和"只是点了一下"）
    private var dragAccumulated: CGFloat = 0
    /// 自测/调试用：假装鼠标在某个位置（这个环境里拿不到真实鼠标事件）
    private var fakeCursor: NSPoint?
    private var capsuleNoticeWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusResetItem: DispatchWorkItem?
    private var keyMonitor: Any?

    private var apps: [NSRunningApplication] = []
    private var appCount = 0
    private var lastSignature: [String] = []
    private var reloadCounter = 0

    // 快捷键
    private let hotKey = HotKeyManager()
    private var hotKeyCode = Int(kVK_ANSI_K)
    private var hotKeyMods = Int(cmdKey | optionKey)
    private var hotKeyLabel = "⌥⌘K"

    // 偏好
    private let pinKey = "panelAlwaysOnTop"
    private let islandKey = "showIslandCapsule"
    private let hidesInNotchKey = "hideCapsuleInNotch"
    /// 被拖动后面板的**绝对位置**（Cocoa 屏幕坐标下的左上角）。**只在这一次展开期间有效**：
    /// 不落盘、不按屏幕记忆，每次 `expand` 都清空 —— 用户要的行为就是"打开就在初始位置"。
    ///
    /// ⚠️ 存绝对坐标而不是"相对当前屏中心的偏移"，是因为偏移得配一个基准，
    /// 而基准是 `currentScreen()`（看鼠标在哪块屏）。鼠标一跨屏，基准整块跳掉，
    /// 面板就会瞬间平移到另一块屏的"对应位置"——大屏右侧一拖到小屏，就闪到小屏右侧去了。
    private var draggedTopLeft: NSPoint?
    /// 正在跑的展开/收起动画。同一时刻只允许一个：新动画会取消旧的，并从当前帧接着走
    /// （所以"展开到一半又收起"不会跳，只会顺着当前速度拐回去）
    private var morphDriver: SpringDriver?
    /// 这一轮动画采样要落到的目标帧（自测用，开跑时定下来）
    private var morphTarget: NSRect?
    /// 展开动画的帧采样（只有自测用，看轨迹顺不顺、有没有跳帧）
    private var morphTrack: [NSRect] = []
    /// 动画期间被推迟的 reload
    private var deferredReload: DispatchWorkItem?
    /// 旧版把位置按屏幕存成 UserDefaults（`islandPositionOffsets`）。启动时清一次，
    /// 免得老用户升级后留下一份谁也不读的数据。
    private let legacyPositionKey = "islandPositionOffsets"
    private let hotKeyCodeKey = "hotKeyCode"
    private let hotKeyModsKey = "hotKeyModifiers"
    private let hotKeyLabelKey = "hotKeyLabel"
    private let checkUpdatesKey = "checkForUpdatesAutomatically"
    private let lastUpdateCheckKey = "lastUpdateCheckAt"
    /// Sparkle 应用内更新（横幅点击 → 下载替换重启）
    private var updaterController: SPUStandardUpdaterController?
    /// 远端查到的新版本（没有就是 nil）
    private var availableUpdate: (version: String, url: URL)?
    private var updateTimer: Timer?

    private let defaultStatus = "✕ 彻底关闭应用 · 点卡片激活 · 鼠标移开自动收起"

    private let debugEnabled = ProcessInfo.processInfo.environment["CLOSEAPPS_DEBUG"] != nil
    private let selfTestEnabled = ProcessInfo.processInfo.environment["CLOSEAPPS_SELFTEST"] != nil
    private func dbg(_ message: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data(("[closeapps] " + message + "\n").utf8))
    }

    private func dumpState(_ tag: String) {
        guard debugEnabled else { return }
        dbg("state[\(tag)]: expanded=\(isExpanded) pinned=\(isPinned) apps=\(appCount) "
            + "trusted=\(axTrusted()) frame=\(panel.frame) detailAlpha=\(detail.alphaValue) "
            + "visible=\(panel.isVisible) cards=\(cardGrid.subviews.count) "
            + "loginItem=\(LoginItem.isEnabled) hotkey=\(hotKeyLabel) "
            + "notch=\(currentScreen().notchRect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "无") "
            + "藏刘海=\(hidesInNotchNow(on: currentScreen())) 容器alpha=\(container?.alphaValue ?? -1) 阴影=\(panel?.hasShadow ?? false) "
            + "拖动=\(offsetText()) 重开锁=\(reopenBlocked) 命中区=\(rectText(collapsedHitRect)) "
            + "样式=\(collapsedStyle(on: currentScreen())) 菜单栏高=\(Int(currentScreen().menuBarHeight)) "
            + "折叠框=\(rectText(islandFrame(expanded: false))) 展开框=\(rectText(islandFrame(expanded: true))) "
            + "更新=\(availableUpdate.map { "有 \($0.version)" } ?? "无") 自动检查=\(checkUpdatesEnabled) "
            + "横幅高=\(Int(updateBannerHeight?.constant ?? -1))")
    }

    /// 调试指令 `hidden [应用名关键字]`：把「跨桌面捞窗口」的全过程打出来 ——
    /// AX 直接给了几个、系统窗口列表说有几个、还差哪些、暴力枚举捞到几个、扫了多少 ID / 花了多久。
    ///
    /// 存在的意义：本机**没有屏幕录制权限**，屏幕上到底有几个窗口肉眼看不见，
    /// 但「系统列表说有 N 个，AX 只给了 M 个，捞回 K 个」这组数字是可断言的。
    /// 同一个应用不带关键字时会把所有应用都过一遍（会同步跑暴力枚举，慢，仅调试用）。
    private func debugHiddenWindows(_ arg: String) {
        let candidates = cgCandidateWindowIDs()
        let apps = arg.isEmpty ? visibleApps : visibleApps.filter {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(arg)
        }
        guard !apps.isEmpty else {
            dbg("hidden: 没有匹配「\(arg)」的运行中应用")
            return
        }
        for app in apps {
            let pid = app.processIdentifier
            let cg = candidates[pid] ?? []
            // 故意不传 cgCandidates：先看"AX 自己肯给的"有几个，才能看出到底漏没漏
            let direct = axWindows(for: app, cgCandidates: [])
            let known = Set(direct.compactMap { axWindowID($0.ref) })
            let missing = cg.subtracting(known)
            dbg("hidden: 「\(app.localizedName ?? "?")」AX 直接给 \(direct.count) 个 "
                + "\(direct.map { $0.title }) ｜ 系统列表候选 \(cg.count) 个 ｜ 缺席 \(missing.count) 个 \(missing.sorted())")
            guard !missing.isEmpty else { continue }
            let r = bruteForceWindowElements(pid: pid, wanted: missing, ceilID: hiddenScanStartCeil,
                                             budgetMs: hiddenScanBudgetMs)
            let titles = r.elements.map { axText($0, kAXTitleAttribute as String) }
            dbg(String(format: "hidden:   暴力枚举 扫 %d 个 ID / %.0fms（最大有效 ID %d）→ 捞到 %d 个 %@ ｜ 仍缺 %d 个",
                       r.scanned, r.elapsedMs, Int(r.maxValidID), r.elements.count,
                       "\(titles)", r.remaining.count))
        }
    }

    /// 调试指令 `raise <应用名关键字> [窗口序号]`：模拟「点某张窗口卡」，并打印前台应用的变化。
    ///
    /// 存在的意义：本机**没有屏幕录制权限**，"点了到底有没有反应"肉眼看不见，
    /// 但 `NSWorkspace.frontmostApplication` 的前后变化是能当断言的 ——
    /// 只调 `AXRaise` 那版在这里会打印「❌ 仍在后面」，补上 activate 之后才会变 ✅。
    private func debugRaiseWindow(_ arg: String) {
        let parts = arg.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard let needle = parts.first else {
            dbg("usage: raise <应用名关键字> [窗口序号]")
            return
        }
        let index = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").contains(needle)
        }) else {
            dbg("raise: 没找到「\(needle)」")
            return
        }
        let wins = axWindows(for: app, cgCandidates: cgCandidateWindowIDs()[app.processIdentifier] ?? [])
        guard wins.indices.contains(index) else {
            dbg("raise: 「\(needle)」只有 \(wins.count) 个窗口，取不到 #\(index)")
            return
        }
        let win = wins[index]
        let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
        dbg("raise: 目标=「\(needle)」#\(index) 标题=「\(win.title)」最小化=\(win.minimized) ｜ 前前台=\(before)")
        bringWindowForward(app: app, win: win)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
            let ok = (NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)
            self.dbg("raise: 0.9s 后前台=\(after) → \(ok ? "✅ 已提到前台" : "❌ 仍在后面")")
        }
    }

    /// 把展开态的面板导出成 PNG，给文档配图 / 演示素材用（stdin 指令 `shot`）。
    ///
    /// 走的是 AppKit 自己的绘制路径（`cacheDisplay`），**不需要屏幕录制权限** ——
    /// 这也是本机唯一能拿到面板真实外观的办法（`screencapture` 会报
    /// `could not create image from display`）。
    /// ⚠️ 代价是拿不到 WindowServer 合成的毛玻璃模糊：导出的是**实底**（深灰）+
    /// 真实的内容排版与圆角。要"透出桌面"得在合成阶段自己补一层背景模糊。
    ///
    /// `shot` → 一张完整列表；`shot 0 1 2` → 各出一张，数字表示**丢掉最前面几个应用**，
    /// 用来拼「点掉几个应用」的演示（只改渲染时用的列表，不会真去关任何应用）。
    private func dumpPanelShots(_ limits: [Int]) {
        // ⚠️ 必须先钉住：真实光标不在面板上时，hover 看门狗（0.12s）会在展开后
        // 立刻把它收起来，等 0.6s 再渲染只能拿到收起到一半的中间态
        // （踩过：导出成 239×118 的怪尺寸）。isPinned 会走 mouseExitedIsland 的
        // 早退分支，正好拿来临时抑制收起；只动内存变量，不碰按钮外观和 UserDefaults。
        let pinBefore = isPinned
        isPinned = true
        if !isExpanded { expand(activateApp: false) }

        var delay = 0.7
        for n in limits {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.debugAppDrop = max(0, n)
                self.reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                    self.writePanelShot(label: n > 0 ? "drop\(n)" : "all")
                }
            }
            delay += 0.6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.3) {
            self.debugAppDrop = 0
            self.isPinned = pinBefore
            self.reload()
            self.dbg("shot: 导出结束，共 \(limits.count) 张")
        }
    }

    private func writePanelShot(label: String) {
        guard let view = panel.contentView else {
            dbg("shot: 面板没有 contentView")
            return
        }
        // 临时藏掉「未授权」提示条：正常用起来（授权后）本来就不显示它，
        // 拿去做演示素材时挂一条橙色警告太出戏。导出完立刻还原。
        let bannerHidden = authBanner.isHidden
        let bannerHeight = authBannerHeight.constant
        authBanner.isHidden = true
        authBannerHeight.constant = 0
        view.layoutSubtreeIfNeeded()

        let bounds = view.bounds
        // 强制 @2x：面板停在哪块屏不由我们定（本机外接屏只有 1x），素材要经得起放大
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            authBanner.isHidden = bannerHidden
            authBannerHeight.constant = bannerHeight
            dbg("shot: 建不出位图")
            return
        }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)

        authBanner.isHidden = bannerHidden
        authBannerHeight.constant = bannerHeight
        view.layoutSubtreeIfNeeded()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            dbg("shot: PNG 编码失败")
            return
        }
        let path = "/tmp/closeapps-panel-\(label).png"
        try? data.write(to: URL(fileURLWithPath: path))
        let f = panel.frame
        dbg("shot[\(label)]: 已导出 \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)px "
            + "应用=\(appCount) 卡片=\(cardGrid.subviews.count) "
            + "panel.frame=(\(Int(f.minX)),\(Int(f.minY))) \(Int(f.width))x\(Int(f.height)) "
            + "屏幕=\(currentScreen().localizedName)")
    }

    /// 仅调试（stdin 指令 `mask`）：把假刘海的遮罩真的算出来、导出成 PNG、再探四个角的像素。
    /// 形状这事嘴上说不清 —— 直角还是圆角、圆角多大，直接看图 + 报数。

    private func dumpMask() {
        let screen = currentScreen()
        let scale = screen.backingScaleFactor
        let size = NSSize(width: Cfg.capsuleWidth, height: capsuleBarHeight(on: screen))
        let installed = blur?.maskImage?.size ?? .zero
        dbg("mask: 屏幕=\(screen.localizedName) 有刘海=\(screen.notchRect != nil) 刻度=\(scale)x 折叠样式=\(collapsedStyle(on: screen))")
        dbg("mask: 现值=\(Int(installed.width))x\(Int(installed.height)) 待验=\(Int(size.width))x\(Int(size.height)) 圆角=\(Cfg.fakeNotchRadius)")

        let image = Self.notchMask(size: size, radius: Cfg.fakeNotchRadius, scale: scale)
        guard let rep = image.representations.first as? NSBitmapImageRep else {
            dbg("mask: 拿不到位图，导出失败")
            return
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        // NSBitmapImageRep 的 y=0 是图像最上面那一行
        func alpha(_ x: Int, _ y: Int) -> Int {
            let c = rep.colorAt(x: min(max(x, 0), w - 1), y: min(max(y, 0), h - 1))
            return Int(((c?.alphaComponent ?? 0) * 255).rounded())
        }
        dbg("mask: \(w)x\(h)px 上缘中点=\(alpha(w / 2, 0)) 左上角=\(alpha(0, 0)) 右上角=\(alpha(w - 1, 0)) "
            + "下缘中点=\(alpha(w / 2, h - 1)) 左下角=\(alpha(0, h - 1)) 右下角=\(alpha(w - 1, h - 1))")
        var gap = -1
        for x in 0..<w where alpha(x, h - 1) > 128 { gap = x; break }
        dbg("mask: 下缘左侧留白=\(gap)px（圆角 \(Cfg.fakeNotchRadius)pt × 刻度 \(scale) = \(Int(Cfg.fakeNotchRadius * scale))px）")
        if let data = rep.representation(using: .png, properties: [:]) {
            let path = "/tmp/closeapps-mask.png"
            try? data.write(to: URL(fileURLWithPath: path))
            dbg("mask: 已导出 \(path)")
        }
        // 再验一张"能逐帧重做的小图"：展开/收起动画里用的就是它（四角半径可以不一样，
        // 这里按"假刘海"的参数出图：上缘直角 + 下缘 16 圆角）
        let stretch = Self.panelMask(topRadius: 0, bottomRadius: Cfg.fakeNotchRadius)
        var proposed = NSRect(origin: .zero, size: stretch.size)
        if let cg = stretch.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            let rep2 = NSBitmapImageRep(cgImage: cg)
            let w2 = rep2.pixelsWide, h2 = rep2.pixelsHigh
            func alpha2(_ x: Int, _ y: Int) -> Int {
                let c = rep2.colorAt(x: min(max(x, 0), w2 - 1), y: min(max(y, 0), h2 - 1))
                return Int(((c?.alphaComponent ?? 0) * 255).rounded())
            }
            dbg("mask(小图/动画用): \(w2)x\(h2)px 上缘中点=\(alpha2(w2 / 2, 0)) 左上角=\(alpha2(0, 0)) "
                + "右上角=\(alpha2(w2 - 1, 0)) 下缘中点=\(alpha2(w2 / 2, h2 - 1)) "
                + "左下角=\(alpha2(0, h2 - 1)) 右下角=\(alpha2(w2 - 1, h2 - 1))")
            if let data2 = rep2.representation(using: .png, properties: [:]) {
                let path2 = "/tmp/closeapps-panelmask.png"
                try? data2.write(to: URL(fileURLWithPath: path2))
                dbg("mask: 已导出 \(path2)")
            }
        } else {
            dbg("mask: 小图渲染失败（panelMask 出图有问题）")
        }

        // 再出一张 2x 的：形状和上边那张是同一个函数算的，只是给预览图用，贴到 2 倍画布上不糊
        let big = Self.notchMask(size: size, radius: Cfg.fakeNotchRadius, scale: 2)
        if let bigRep = big.representations.first as? NSBitmapImageRep,
           let data = bigRep.representation(using: .png, properties: [:]) {
            let path = "/tmp/closeapps-mask@2x.png"
            try? data.write(to: URL(fileURLWithPath: path))
            dbg("mask: 已导出 \(path)（\(bigRep.pixelsWide)x\(bigRep.pixelsHigh)px，给预览用）")
        }

        // 再来一张"关掉藏进刘海时那枚胶囊"的（176×36）：同一个 0/16 形状，只是条高不一样
        let capSize = NSSize(width: Cfg.capsuleWidth, height: Cfg.capsuleSize.height)
        let cap = Self.notchMask(size: capSize, radius: Cfg.fakeNotchRadius, scale: 2)
        if let capRep = cap.representations.first as? NSBitmapImageRep,
           let data = capRep.representation(using: .png, properties: [:]) {
            let path = "/tmp/closeapps-capsule@2x.png"
            try? data.write(to: URL(fileURLWithPath: path))
            dbg("mask: 已导出 \(path)（\(capRep.pixelsWide)x\(capRep.pixelsHigh)px = 胶囊 "
                + "\(Int(capSize.width))x\(Int(capSize.height))）")
        }
    }

    /// 仅调试模式（CLOSEAPPS_SELFTEST=1）：内置时序，自测展开/收起/开关，
    /// 最后调 NSApp.terminate 验证退出链路。不需要任何外部交互。
    private func runSelfTest() {
        guard selfTestEnabled else { return }
        // 这个环境拿不到真实鼠标事件，所以自测统一"注入假坐标 + 走真实判定函数"，
        // 验的就是 expand / collapse / 轮询 / 重开锁 / 拖动这条链路本身。
        let place: (NSPoint) -> () -> Void = { point in
            { [weak self] in self?.fakeCursor = point }
        }
        let script: [(String, TimeInterval, () -> Void)] = [
            ("dump@① 启动初始态", 0.35, { [weak self] in self?.dumpState("① 启动初始态") }),

            // ① 悬停 → 展开（走真实的 mouseEnteredIsland，坐标核验也在里面）
            ("假光标=胶囊中心", 0.60, { [weak self] in self?.fakeCursor = self?.capsuleCenter() }),
            ("hover-enter", 0.70, { [weak self] in self?.mouseEnteredIsland() }),
            ("dump@② 悬停展开", 1.10, { [weak self] in self?.dumpState("② 悬停展开") }),

            // ② ★问题1 回归：光标停在"刘海那一带"（在命中区里、却在展开面板之外）1.5s，不该收起
            ("假光标=刘海那一带", 1.30, { [weak self] in
                self?.fakeCursor = self?.hoverGraceProbe()
                self?.dbg("grace probe = \(self?.fakeCursor ?? .zero)")
            }),
            ("dump@③ 停在那儿 1.5s（应仍展开）", 2.80, { [weak self] in self?.dumpState("③ 停在那儿 1.5s") }),

            // ③ 真移开 → 自动收起
            ("假光标=远处", 3.00, place(NSPoint(x: 120, y: 300))),
            ("dump@④ 移开后（应已收起）", 3.90, { [weak self] in self?.dumpState("④ 移开后") }),

            // ④ ★问题2 回归：移开后马上再 hover，不该被时间窗挡住
            ("假光标=胶囊中心", 4.05, { [weak self] in self?.fakeCursor = self?.capsuleCenter() }),
            ("hover-enter（连续 hover）", 4.15, { [weak self] in self?.mouseEnteredIsland() }),
            ("dump@⑤ 连续 hover 再展开", 4.65, { [weak self] in self?.dumpState("⑤ 连续 hover 再展开") }),

            // ⑤ 光标没动时收起 → 加锁；挪开再回来才放行
            ("toggle（光标还在命中区）", 4.95, { [weak self] in self?.toggleFromKeyboard() }),
            ("hover-enter（应被拦）", 5.25, { [weak self] in self?.mouseEnteredIsland() }),
            ("dump@⑥ 没离开时重开被拦", 5.65, { [weak self] in self?.dumpState("⑥ 重开被拦") }),
            ("假光标=远处", 5.85, place(NSPoint(x: 120, y: 300))),
            ("假光标=回胶囊中心", 6.35, { [weak self] in self?.fakeCursor = self?.capsuleCenter() }),
            ("hover-enter（应放行）", 6.45, { [weak self] in self?.mouseEnteredIsland() }),
            ("dump@⑦ 挪开后重开成功", 6.95, { [weak self] in self?.dumpState("⑦ 挪开后重开成功") }),

            // ⑥ 拖动 + 重置位置
            ("collapse", 7.20, { [weak self] in self?.collapse(animated: false) }),
            ("drag +120,-60", 7.60, { [weak self] in self?.simulateDrag(dx: 120, dy: -60) }),
            ("check 胶囊没被拖走", 7.90, { [weak self] in self?.probeCapsulePinned() }),
            ("check 面板滚区形状（收起态）", 7.45, { [weak self] in self?.probeCapsuleShape() }),
            ("dump@⑧ 拖动后", 8.10, { [weak self] in self?.dumpState("⑧ 拖动后") }),
            ("resetpos", 8.40, { [weak self] in self?.resetIslandPosition() }),
            ("dump@⑨ 重置后", 8.90, { [weak self] in self?.dumpState("⑨ 重置后") }),

            // ⑦ 开机启动 / 藏刘海开关
            // ★ 只读：以前这里真的开关一遍开机项，等于把开机项重挂到"当时跑的那份副本"上
            ("check 开机启动（只读）", 9.20, { [weak self] in self?.probeLoginItem() }),
            ("check 更新检查逻辑", 9.35, { [weak self] in self?.probeUpdateCheck() }),
            ("dump@⑪ 开机启动态", 9.60, { [weak self] in self?.dumpState("⑪ 开机启动态") }),
            ("notch-off", 12.20, { [weak self] in self?.menuToggleHidesInNotch() }),
            ("dump@⑫ 不藏刘海（贴顶胶囊）", 12.80, { [weak self] in self?.dumpState("⑫ 不藏刘海") }),
            ("check 胶囊形状（关掉藏刘海那态）", 12.95, { [weak self] in self?.probeCapsuleShape() }),
            ("notch-on", 13.10, { [weak self] in self?.menuToggleHidesInNotch() }),
            ("dump@⑬ 恢复藏刘海", 13.70, { [weak self] in self?.dumpState("⑬ 恢复藏刘海") }),

            // ⑧ ★「面板拖不动」回归：展开态按住标题栏也要能拖。
            //    以前 hover 一上来就展开，按下时 isExpanded 早已为 true，被 guard 吞掉 → 永远拖不动。
            //    这里走非激活展开：快捷键展开会先激活 App，动画得等激活完才起步，日志会看着像"没动"
            ("expand", 13.85, { [weak self] in self?.expand(activateApp: false) }),
            ("track 展开动画", 13.90, { [weak self] in self?.trackMorphMotion("展开") }),
            ("假光标=展开面板中心", 14.15, { [weak self] in
                guard let self else { return }
                self.fakeCursor = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.midY)
            }),
            ("dump@⑭ 展开态", 14.45, { [weak self] in self?.dumpState("⑭ 展开态") }),
            // 右上角按钮必须点得到（不能被拖动把手抢走）
            // 放到 15.10：这之前面板必须已经长到最终尺寸，否则量的是动画中途的容器
            ("hit-test 右上角按钮", 15.10, { [weak self] in self?.probeHeaderHitTest() }),
            // ★ 滚动条要展开着量：收起时滚动区根本没布局
            ("check 滚动条宽度", 15.08, { [weak self] in self?.probeScroller() }),
            ("drag(展开态) +80,-70", 14.65, { [weak self] in self?.simulateDrag(dx: 80, dy: -70) }),
            ("假光标=跟到新位置", 14.95, { [weak self] in
                guard let self else { return }
                self.fakeCursor = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.midY)
            }),
            ("dump@⑮ 展开态拖动后", 15.15, { [weak self] in self?.dumpState("⑮ 展开态拖动后") }),
            ("check 跨屏拖动不跳", 15.25, { [weak self] in self?.probeCrossScreenDrag() }),
            // ★ 「打开就回初始位置」回归：拖开之后收起，再打开必须回到默认框
            ("collapse（准备验重开）", 15.35, { [weak self] in self?.collapse(animated: false) }),
            ("check 假刘海形状（无刘海屏）", 15.42, { [weak self] in self?.probeFakeNotchShape() }),
            ("expand（重开）", 15.60, { [weak self] in self?.expand(activateApp: false) }),
            ("check 重开是否回初始位置", 16.10, { [weak self] in self?.probeExpandResetsPosition() }),
            ("dump@⑯ 重开后（应回初始位置）", 16.25, { [weak self] in self?.dumpState("⑯ 重开后") }),
            ("quit", 17.10, { [weak self] in
                self?.dbg("selftest: 调用 NSApp.terminate")
                NSApp.terminate(nil)
                self?.dbg("selftest: terminate 返回了但进程没退出 ← 问题在这")
            }),
        ]
        for (name, delay, action) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.dbg("selftest step: \(name)")
                action()
            }
        }
    }

    /// 仅调试模式（CLOSEAPPS_DEBUG=1）：从 stdin 收指令驱动面板，方便在没有鼠标事件的
    /// 环境里（自动化测试、远程会话）验证展开/收起状态机。普通使用完全不会走到这里。
    private func startDebugConsole() {
        guard debugEnabled, !selfTestEnabled else { return }
        DispatchQueue.global(qos: .utility).async {
            while let raw = readLine(strippingNewline: true) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if line.hasPrefix("mouse ") {
                        self.debugSetFakeCursor(String(line.dropFirst(6)))
                        return
                    }
                    if line.hasPrefix("fakeupdate ") {
                        self.simulateUpdateBanner(String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces))
                        return
                    }
                    if line.hasPrefix("drag ") {
                        let parts = line.dropFirst(5).split(separator: " ").compactMap { Double($0) }
                        guard parts.count == 2 else { self.dbg("usage: drag <dx> <dy>"); return }
                        self.simulateDrag(dx: CGFloat(parts[0]), dy: CGFloat(parts[1]))
                        return
                    }
                    if line == "shot" || line.hasPrefix("shot ") {
                        let nums = line.dropFirst(4).split(separator: " ").compactMap { Int($0) }
                        self.dumpPanelShots(nums.isEmpty ? [0] : nums)
                        return
                    }
                    if line == "hidden" || line.hasPrefix("hidden ") {
                        self.debugHiddenWindows(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
                        return
                    }
                    if line.hasPrefix("raise ") {
                        self.debugRaiseWindow(String(line.dropFirst(6)))
                        return
                    }
                    switch line {
                    case "hover-enter": self.mouseEnteredIsland()
                    case "resetpos": self.resetIslandPosition()
                    case "hover-exit": self.mouseExitedIsland()
                    case "expand": self.expand(activateApp: false)
                    case "expand-key": self.expand(activateApp: true)
                    case "collapse": self.collapse(animated: true)
                    case "toggle": self.toggleFromKeyboard()
                    case "pin": self.togglePin()
                    case "island": self.menuToggleIsland()
                    case "notch": self.menuToggleHidesInNotch()
                    case "login": self.menuToggleLoginItem()
                    case "update": self.checkForUpdate(manual: true)
                    case "sparkle":
                        self.dbg("sparkle: 前台检查更新")
                        self.updaterController?.checkForUpdates(nil)
                    case "update-clear": self.hideUpdateBanner()
                    case "dump": self.dumpState("dump")
                    case "mask": self.dumpMask()
                    case "shape":
                        self.probeCapsuleShape()
                        self.probeScroller()
                    case "quit":
                        self.dbg("quit: calling NSApp.terminate")
                        NSApp.terminate(nil)
                        self.dbg("quit: terminate returned (did not exit)")
                    case "quit-now":
                        self.dbg("quit-now: exit(0)")
                        exit(0)
                    default: self.dbg("unknown command: \(line)")
                    }
                }
            }
            self.dbg("stdin 已关闭，调试控制台停止读取")
        }
    }

    /// 调试/自测用：注入假的光标位置（`mouse 756 491` / `mouse clear`）。
    /// 这个环境里投递鼠标事件会被系统权限挡掉，只能这样验坐标判定逻辑。
    private func debugSetFakeCursor(_ arg: String) {
        let text = arg.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == "clear" {
            fakeCursor = nil
            dbg("假光标已清除（回到真实位置）")
            return
        }
        let parts = text.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else {
            dbg("usage: mouse <x> <y> | mouse clear")
            return
        }
        fakeCursor = NSPoint(x: parts[0], y: parts[1])
        dbg("假光标 -> \(Int(parts[0])),\(Int(parts[1])) 屏=\(currentScreen().displayID)")
    }

    // MARK: 生命周期

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle 应用内更新：SUEnableAutomaticChecks=false，平时完全静默，
        // 更新横幅点击时才前台检查并「下载 → 替换 → 重启」一条龙
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        if UserDefaults.standard.object(forKey: islandKey) == nil {
            UserDefaults.standard.set(true, forKey: islandKey)
        }
        if UserDefaults.standard.object(forKey: hidesInNotchKey) == nil {
            UserDefaults.standard.set(true, forKey: hidesInNotchKey)
        }
        // 位置从 v1.6 起不缓存了，把旧版存的那份清掉
        dropLegacyPositionMemory()
        buildPanel()
        buildStatusItem()
        setupHotKey()
        isPinned = UserDefaults.standard.bool(forKey: pinKey)
        applyPinAppearance()
        updateCounts()
        applyIslandVisibility()
        dbg("launched: screen=\(currentScreen().frame) visible=\(currentScreen().visibleFrame) capsule=\(islandFrame(expanded: false))")
        startDebugConsole()
        runSelfTest()
        // 自测不联网：网络那步只做人工验证，别让自测结果取决于今天的网通不通
        if !selfTestEnabled { scheduleUpdateCheck() }
        lastScreenID = currentScreen().displayID
        screenWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.followMouseScreen()
        }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshLightweight() })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshLightweight() })
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 展开状态下按 Esc 收起
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.isExpanded, !self.recorder.isRecording {
                self.collapse(animated: true)
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        dbg("applicationShouldTerminate -> terminateNow")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        dbg("applicationWillTerminate")
        refreshTimer?.invalidate()
        updateTimer?.invalidate()
        screenWatchTimer?.invalidate()
        stopHoverPoll()
        reopenWatchTimer?.invalidate()
        reopenWatchTimer = nil
        hotKey.unregister()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// 常驻：面板关掉也不退出应用
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 界面搭建

    private func buildPanel() {
        let p = IslandPanel(contentRect: islandFrame(expanded: false),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.becomesKeyOnlyIfNeeded = false
        p.title = "应用关闭面板"
        panel = p

        let hover = HoverView(frame: NSRect(origin: .zero, size: Cfg.capsuleSize))
        hover.wantsLayer = true
        hover.layer?.masksToBounds = true
        hover.layer?.cornerRadius = Cfg.cornerRadius
        hover.onEnter = { [weak self] in self?.mouseEnteredIsland() }
        hover.onExit = { [weak self] in self?.mouseExitedIsland() }
        hover.onDragBegin = { [weak self] in self?.beginIslandDrag() }
        hover.onDrag = { [weak self] dx, dy in self?.dragIslandBy(dx: dx, dy: dy) }
        hover.onDragEnd = { [weak self] in self?.endIslandDrag() }
        hover.shouldCaptureMouse = { [weak self] hitView, _ in
            guard let self else { return false }
            return self.shouldCaptureMouseForDrag(hitView: hitView)
        }
        container = hover
        p.contentView = hover

        let effect = NSVisualEffectView(frame: hover.bounds)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.maskImage = Self.roundedMask(radius: Cfg.cornerRadius)
        hover.addSubview(effect)
        blur = effect

        buildHeader()
        buildDetail()

        p.setFrame(islandFrame(expanded: false), display: false)
    }

    /// 头部：固定 596 宽、水平居中，窗口变窄时被裁掉两侧——只剩中间那枚胶囊
    private func buildHeader() {
        let h = NSView(frame: .zero)
        h.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(h)
        header = h
        let hHeight = h.heightAnchor.constraint(equalToConstant: Cfg.headerHeight)
        headerHeightConstraint = hHeight
        dragHandleViews.append(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: container.topAnchor),
            h.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            h.widthAnchor.constraint(equalToConstant: Cfg.expandedSize.width),
            hHeight,
        ])

        // 折叠态胶囊内容（居中于面板正中，展开时淡出）
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: "正在运行")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        capsuleLabel = label

        let badge = NSView(frame: .zero)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 8).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 8).isActive = true
        badge.isHidden = true
        badge.toolTip = "还没授权「辅助功能」，看不到窗口列表"
        capsuleBadge = badge

        let stack = NSStackView(views: [icon, label, badge])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        h.addSubview(stack)
        capsuleStack = stack
        dragHandleViews.append(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: h.centerYAnchor),
        ])

        // 展开态标题（居左）
        let title = NSTextField(labelWithString: "正在运行的应用")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        h.addSubview(title)
        titleLabel = title
        dragHandleViews.append(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: h.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: h.centerYAnchor),
        ])

        // 展开态控件（居右）
        let rec = HotKeyRecorder()
        rec.translatesAutoresizingMaskIntoConstraints = false
        rec.widthAnchor.constraint(equalToConstant: 72).isActive = true
        rec.heightAnchor.constraint(equalToConstant: 22).isActive = true
        rec.onClick = { [weak self] in self?.beginRecordingHotKey() }
        rec.onCancel = { [weak self] in self?.finishRecordingHotKey() }
        rec.onCapture = { [weak self] code, mods, label in
            self?.applyHotKey(code: Int(code), mods: Int(mods), label: label)
            self?.finishRecordingHotKey()
        }
        recorder = rec

        let pin = NSButton()
        pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "置顶")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        pin.isBordered = false
        pin.contentTintColor = .secondaryLabelColor
        pin.target = self
        pin.action = #selector(togglePin)
        pin.toolTip = "钉住面板（鼠标移开也不收起）"
        pin.setAccessibilityLabel("钉住面板")
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.widthAnchor.constraint(equalToConstant: 24).isActive = true
        pin.heightAnchor.constraint(equalToConstant: 22).isActive = true
        pinButton = pin

        let refresh = NSButton()
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        refresh.isBordered = false
        refresh.contentTintColor = .secondaryLabelColor
        refresh.target = self
        refresh.action = #selector(manualRefresh)
        refresh.toolTip = "立即刷新"
        refresh.setAccessibilityLabel("刷新")
        refresh.translatesAutoresizingMaskIntoConstraints = false
        refresh.widthAnchor.constraint(equalToConstant: 24).isActive = true
        refresh.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let collapseButton = NSButton()
        collapseButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "收起")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        collapseButton.isBordered = false
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.target = self
        collapseButton.action = #selector(collapseNow)
        collapseButton.toolTip = "收起面板（Esc）"
        collapseButton.setAccessibilityLabel("收起面板")
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        collapseButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let controls = NSStackView(views: [rec, pin, refresh, collapseButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false
        h.addSubview(controls)
        controlsStack = controls
        NSLayoutConstraint.activate([
            controls.trailingAnchor.constraint(equalTo: h.trailingAnchor, constant: -14),
            controls.centerYAnchor.constraint(equalTo: h.centerYAnchor),
        ])

        expandedOnly = [title, controls]
        expandedOnly.forEach { $0.alphaValue = 0 }
    }

    /// 详情区：固定 596 宽、挂在头部下方，折叠时整体被容器裁掉
    private func buildDetail() {
        let d = NSView(frame: .zero)
        d.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(d)
        detail = d
        NSLayoutConstraint.activate([
            d.topAnchor.constraint(equalTo: container.topAnchor, constant: Cfg.headerHeight),
            d.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            d.widthAnchor.constraint(equalToConstant: Cfg.expandedSize.width),
            d.heightAnchor.constraint(equalToConstant: Cfg.detailSize.height),
        ])

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

        updateBanner = NSButton(
            title: "有新版本可用，点这里查看 →",
            target: self,
            action: #selector(openUpdatePage)
        )
        updateBanner.font = .systemFont(ofSize: 11, weight: .medium)
        updateBanner.isBordered = false
        updateBanner.contentTintColor = .systemBlue
        updateBanner.alignment = .center
        updateBanner.isHidden = true
        updateBanner.translatesAutoresizingMaskIntoConstraints = false

        cardGrid = CardGridView(frame: .zero)
        cardGrid.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = cardGrid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.verticalScroller = ThinScroller()      // 细一号（见 ThinScroller）
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollView = scroll

        emptyLabel = NSTextField(labelWithString: "没有正在运行的应用")
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        statusLabel = NSTextField(labelWithString: defaultStatus)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        d.addSubview(authBanner)
        d.addSubview(updateBanner)
        d.addSubview(scroll)
        d.addSubview(emptyLabel)
        d.addSubview(statusLabel)

        authBannerHeight = authBanner.heightAnchor.constraint(equalToConstant: 0)
        updateBannerHeight = updateBanner.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            authBanner.topAnchor.constraint(equalTo: d.topAnchor, constant: 4),
            authBanner.leadingAnchor.constraint(equalTo: d.leadingAnchor, constant: 18),
            authBanner.trailingAnchor.constraint(equalTo: d.trailingAnchor, constant: -18),
            authBannerHeight,

            updateBanner.topAnchor.constraint(equalTo: authBanner.bottomAnchor, constant: 2),
            updateBanner.leadingAnchor.constraint(equalTo: d.leadingAnchor, constant: 18),
            updateBanner.trailingAnchor.constraint(equalTo: d.trailingAnchor, constant: -18),
            updateBannerHeight,

            scroll.topAnchor.constraint(equalTo: updateBanner.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: d.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: d.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            cardGrid.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            cardGrid.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: d.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: d.trailingAnchor, constant: -18),
            statusLabel.bottomAnchor.constraint(equalTo: d.bottomAnchor, constant: -10),
        ])
        detail.alphaValue = 0
    }

    /// 假刘海的遮罩：上缘两个直角（贴着屏幕顶沿），下缘两角是普通圆角 —— 就一行 CSS：
    /// `border-radius: 0 0 16px 16px`。有刘海的屏上那块是物理盲区，这里没有，
    /// 只能"画"出一块来，让用户平白多一块刘海。
    ///
    /// 这张图按**真实尺寸**出（不是像 roundedMask 那样出小图 + capInsets 拉伸）：
    /// 圆角 16 而条高只有二十几点，四边 inset 加起来会超过图高，拉伸会退化成一坨。
    private static func notchMask(size: NSSize, radius: CGFloat, scale: CGFloat) -> NSImage {
        let image = NSImage(size: size)
        let w = max(1, Int((size.width * scale).rounded()))
        let h = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        NSColor.black.setFill()
        Self.notchPath(in: NSRect(origin: .zero, size: size), radius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    /// 上缘直角 + 下缘两角圆角（= CSS `border-radius: 0 0 16px 16px`）
    private static func notchPath(in rect: NSRect, radius r: CGFloat) -> NSBezierPath {
        let rr = max(0, min(r, rect.height))   // 兜底：圆角不许大过整条高度
        guard rr > 0 else { return NSBezierPath(rect: rect) }
        let path = NSBezierPath()
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        path.move(to: NSPoint(x: x0, y: y1))                                  // 左上角：直角
        path.line(to: NSPoint(x: x1, y: y1))                                  // 上缘：贴着屏幕顶沿
        path.line(to: NSPoint(x: x1, y: y0 + rr))
        path.appendArc(withCenter: NSPoint(x: x1 - rr, y: y0 + rr), radius: rr,
                       startAngle: 0, endAngle: -90, clockwise: true)         // 右下角：普通圆角
        path.line(to: NSPoint(x: x0 + rr, y: y0))                             // 下缘
        path.appendArc(withCenter: NSPoint(x: x0 + rr, y: y0 + rr), radius: rr,
                       startAngle: -90, endAngle: -180, clockwise: true)      // 左下角：普通圆角
        path.line(to: NSPoint(x: x0, y: y1))
        path.close()
        return path
    }

    /// 面板/胶囊通用的遮罩：**四个角的半径可以不一样**。
    ///
    /// 折叠的"假刘海"是上缘直角 + 下缘 16 圆角，展开的面板是四角都 18；
    /// 动画期间这两个数逐帧插值，形状才会跟着一起"长"出来，而不是某一帧突然换掉。
    ///
    /// 出小图 + capInsets 三段拉伸（和 `roundedMask` 一个套路）：半径最大 18，
    /// 一张三十几点见方的小图就够，逐帧重做毫无压力，而且按目标刻度现场绘制，Retina 上不糊。
    private static func panelMask(topRadius: CGFloat, bottomRadius: CGFloat) -> NSImage {
        let side = max(topRadius, bottomRadius)
        let edge = max(1, side * 2 + 1)
        // 图高 = 上圆角 + 下圆角 + 1px 中间带：两头圆角保持原尺寸，只有中间那一条被拉伸
        let size = NSSize(width: edge, height: max(1, topRadius + bottomRadius + 1))
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            Self.perCornerPath(in: rect, top: topRadius, bottom: bottomRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: topRadius, left: side, bottom: bottomRadius, right: side)
        image.resizingMode = .stretch
        return image
    }

    /// 上下圆角各自独立的圆角矩形（顺时针：上缘 → 右上 → 右缘 → 右下 → 下缘 → 左下 → 左缘 → 左上）
    private static func perCornerPath(in rect: NSRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let half = rect.width / 2
        let tr = max(0, min(top, half))
        let br = max(0, min(bottom, half))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0 + tr, y: y1))
        path.line(to: NSPoint(x: x1 - tr, y: y1))
        if tr > 0 {
            path.appendArc(withCenter: NSPoint(x: x1 - tr, y: y1 - tr), radius: tr,
                           startAngle: 90, endAngle: 0, clockwise: true)
        }
        path.line(to: NSPoint(x: x1, y: y0 + br))
        if br > 0 {
            path.appendArc(withCenter: NSPoint(x: x1 - br, y: y0 + br), radius: br,
                           startAngle: 0, endAngle: -90, clockwise: true)
        }
        path.line(to: NSPoint(x: x0 + br, y: y0))
        if br > 0 {
            path.appendArc(withCenter: NSPoint(x: x0 + br, y: y0 + br), radius: br,
                           startAngle: -90, endAngle: -180, clockwise: true)
        }
        path.line(to: NSPoint(x: x0, y: y1 - tr))
        if tr > 0 {
            path.appendArc(withCenter: NSPoint(x: x0 + tr, y: y1 - tr), radius: tr,
                           startAngle: 180, endAngle: 90, clockwise: true)
        }
        path.close()
        return path
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: 菜单栏图标

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let icon = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.image?.isTemplate = false
            button.toolTip = "CloseApps · 应用关闭面板"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            showStatusMenu()
        } else {
            toggleFromKeyboard()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let toggle = NSMenuItem(title: isExpanded ? "收起面板" : "打开面板（\(hotKeyLabel)）",
                                action: #selector(toggleFromKeyboard), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // 有新版就顶在最上面 —— 菜单栏右键是"不打开面板也能看见"的入口
        if let update = availableUpdate {
            let newer = NSMenuItem(title: "↑ 新版本 \(update.version) 可用 · 点击查看",
                                   action: #selector(openUpdatePage), keyEquivalent: "")
            newer.target = self
            menu.addItem(newer)
        }
        menu.addItem(.separator())

        let island = NSMenuItem(title: "显示灵动岛胶囊", action: #selector(menuToggleIsland), keyEquivalent: "")
        island.target = self
        island.state = UserDefaults.standard.bool(forKey: islandKey) ? .on : .off
        menu.addItem(island)

        // 位置不缓存，所以这个菜单项只在"本次打开挪开过"时才出现
        if draggedTopLeft != nil {
            let reset = NSMenuItem(title: "面板回到初始位置", action: #selector(menuResetIslandPosition), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }

        if currentScreen().notchRect != nil {
            let notch = NSMenuItem(title: "折叠时藏进刘海", action: #selector(menuToggleHidesInNotch), keyEquivalent: "")
            notch.target = self
            notch.state = hidesInNotch ? .on : .off
            menu.addItem(notch)
        }

        let login = NSMenuItem(title: "开机自动启动", action: #selector(menuToggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        if LoginItem.needsApproval {
            login.title = "开机自动启动（需在系统设置里允许）"
        }
        menu.addItem(login)

        let hk = NSMenuItem(title: "修改全局快捷键…", action: #selector(menuEditHotKey), keyEquivalent: "")
        hk.target = self
        menu.addItem(hk)

        let checkUpdate = NSMenuItem(title: "检查更新…", action: #selector(menuCheckUpdate), keyEquivalent: "")
        checkUpdate.target = self
        menu.addItem(checkUpdate)

        let autoUpdate = NSMenuItem(title: "自动检查更新", action: #selector(menuToggleCheckUpdates), keyEquivalent: "")
        autoUpdate.target = self
        autoUpdate.state = checkUpdatesEnabled ? .on : .off
        menu.addItem(autoUpdate)

        if !axTrusted() {
            let ax = NSMenuItem(title: "辅助功能权限…", action: #selector(openAXSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 CloseApps", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: 展开 / 收起

    /// 当前"视为"的鼠标位置：普通使用就是真实光标，自测/调试里可以注入假坐标
    private var cursorLocation: NSPoint { fakeCursor ?? NSEvent.mouseLocation }

    private func currentScreen() -> NSScreen {
        let mouse = cursorLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func screen(withID id: UInt32) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    private func rectText(_ r: NSRect) -> String {
        r == .zero ? "无" : "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
    }

    private func offsetText() -> String {
        guard let p = draggedTopLeft else { return "默认" }
        return "\(Int(p.x)),\(Int(p.y))"
    }

    /// 展开面板在某块屏上的尺寸（屏幕太矮就别长到屏幕外面去）
    private func expandedSize(on screen: NSScreen) -> NSSize {
        var size = Cfg.expandedSize
        size.height = min(size.height, screen.visibleFrame.height - 40)
        return size
    }

    /// 所有屏幕拼成的整块桌面。拖动跨屏时得按它来夹 —— 按"鼠标现在在哪块屏"夹的话，
    /// 鼠标一跨过去就会把面板硬拽进新屏里（那正是"瞬间跑过去"的另一个来源）。
    private var desktopBounds: NSRect {
        var union: NSRect?
        for s in NSScreen.screens {
            union = union.map { $0.union(s.frame) } ?? s.frame
        }
        return union ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 按左上角放面板，并夹在 `bounds` 里（`minBottom` 是面板下缘不许越过的线）。
    /// 用左上角而不是左下角：面板顶边是钉在菜单栏/刘海下沿的，夹的时候不能让它顶上去。
    private func clampedPanel(topLeft p: NSPoint, size: NSSize,
                              bounds: NSRect, minBottom: CGFloat) -> NSRect {
        let m = Cfg.dragEdgeMargin
        var x = p.x
        x = min(max(x, bounds.minX + m), max(bounds.minX + m, bounds.maxX - size.width - m))
        var top = min(p.y, bounds.maxY)
        let lowestTop = minBottom + m + size.height
        if lowestTop <= bounds.maxY { top = max(top, lowestTop) }
        return NSRect(x: round(x), y: round(top - size.height), width: size.width, height: size.height)
    }

    /// 清掉旧版的位置记忆（升级后跑一次就够，之后这里是空操作）
    private func dropLegacyPositionMemory() {
        guard UserDefaults.standard.object(forKey: legacyPositionKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: legacyPositionKey)
        dbg("已清掉旧版的位置记忆（位置不再缓存）")
    }

    /// 顶边固定、只往下长：折叠 = 胶囊/假刘海，展开 = 面板。
    ///
    /// 位置规则（v1.7）：**面板每次打开都回到初始位置，位置一律不缓存**。
    /// `draggedTopLeft` 只是本次展开期间的临时位置，`expand` 一进来就清空；
    /// 折叠态的胶囊更是钉在屏幕顶部正中，永远不参与位移。
    private func islandFrame(expanded: Bool) -> NSRect {
        let screen = currentScreen()
        let style = collapsedStyle(on: screen)

        // 藏进刘海：正好铺满那块物理盲区，另外往下多留一点做悬停容错
        if !expanded, style == .hiddenInNotch, let notch = screen.notchRect {
            return NSRect(x: notch.minX,
                          y: notch.minY - Cfg.notchHoverMargin,
                          width: notch.width,
                          height: notch.height + Cfg.notchHoverMargin)
        }

        if expanded {
            let size = expandedSize(on: screen)
            // ★ 被拖过就用**绝对坐标**：跨屏时面板只跟着鼠标走，不会被另一块屏的
            //   midX/顶沿当成新基准重新摆一次（那正是"瞬间跑到第二屏"的根因）
            if let topLeft = draggedTopLeft {
                return clampedPanel(topLeft: topLeft, size: size,
                                    bounds: desktopBounds, minBottom: desktopBounds.minY)
            }
            // 没被拖过：当前屏顶部正中，顶边贴菜单栏/刘海下沿
            let baseTop = screen.notchRect?.minY ?? screen.visibleFrame.maxY
            return clampedPanel(topLeft: NSPoint(x: screen.frame.midX - size.width / 2, y: baseTop),
                                size: size,
                                bounds: screen.frame,
                                minBottom: screen.visibleFrame.minY)
        }

        // 折叠态：顶边贴屏幕顶沿（假刘海）或刘海/菜单栏下沿，水平居中 —— 永远不吃拖动的偏移
        let size = style == .fakeNotch
            ? NSSize(width: Cfg.capsuleWidth, height: capsuleBarHeight(on: screen))
            : NSSize(width: Cfg.capsuleWidth, height: Cfg.capsuleSize.height)
        let baseTop = style == .fakeNotch
            ? screen.frame.maxY
            : (screen.notchRect?.minY ?? screen.visibleFrame.maxY)
        return NSRect(x: round(screen.frame.midX - size.width / 2),
                      y: round(baseTop - size.height),
                      width: size.width, height: size.height)
    }

    /// 这块屏此刻该不该"隐形藏进刘海"：有刘海 + 开关开着就行。
    /// 拖动现在只挪展开的面板，不会再把这个开关搅乱 —— 以前面板一被拖走就判定成
    /// "不在原位"，于是藏起来的胶囊会突然以普通胶囊的样子冒出来。
    private func hidesInNotchNow(on screen: NSScreen) -> Bool {
        hidesInNotch && screen.notchRect != nil
    }

    /// 折叠态在这块屏上的外观
    enum CapsuleStyle {
        /// 有刘海 + 开关开 → 完全隐形（面板铺满刘海那块物理盲区）
        case hiddenInNotch
        /// 没有刘海的屏 → 贴屏幕顶沿做成一枚"假刘海"（上缘直角、下缘两角圆角）
        case fakeNotch
        /// 有刘海但开关关了 → 普通悬浮胶囊，挂在刘海下沿
        case plain
    }

    private func collapsedStyle(on screen: NSScreen) -> CapsuleStyle {
        if hidesInNotchNow(on: screen) { return .hiddenInNotch }
        return screen.notchRect == nil ? .fakeNotch : .plain
    }

    /// 折叠条的"条高"：无刘海屏要和菜单栏一样高，看起来才像一块真刘海
    private func capsuleBarHeight(on screen: NSScreen) -> CGFloat {
        let bar = screen.menuBarHeight
        return bar > 8 ? bar : 24
    }

    func expand(activateApp: Bool) {
        collapseWork?.cancel()
        collapseWork = nil
        // 跨桌面窗口的暴力枚举只在面板展开时做（收起时用户看不到，没必要扫）。必须在 reload 之前置位。
        panelIsExpandedForScan = true
        // 扫描一完成就立刻刷一次（不等下一个 2 秒 tick）。没有这一步，面板刚打开那一轮
        // 必然少一个跨桌面的窗口，要等 2 秒才自己冒出来 —— 用户会以为"有时候不显示"。
        hiddenScanDidFinish = { [weak self] in
            guard let self, self.isExpanded else { return }
            self.reload()
        }
        // ★ 每一次打开都回初始位置：位置不缓存，上次拖动留下的临时位置在这里清空
        draggedTopLeft = nil
        // 本来就已经展开的话（面板开着又按了一次快捷键之类），位置/形状/内容都到位了，
        // 不要再"演"一遍 —— 再演一次会让胶囊内容闪回来、面板内容重新渐显
        let wasExpanded = isExpanded
        if !wasExpanded {
            isExpanded = true
            reload(force: true)
            startRefresh()
            detail.alphaValue = 0
            expandedOnly.forEach { $0.alphaValue = 0 }
            capsuleStack.alphaValue = 1      // 交给动画逐帧淡出（不能再走 animator，会跟逐帧赋值打架）
        }
        // 从刘海/胶囊态出来：视觉和阴影要回来。圆角不在这里定死 ——
        // 折叠态可能根本没有圆角（假刘海），直接换会"跳"一下，交给动画逐帧过渡
        container?.alphaValue = 1
        panel?.hasShadow = true
        headerHeightConstraint?.constant = Cfg.headerHeight

        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
        lastScreenID = currentScreen().displayID
        // 记住这一刻的折叠命中区：展开后鼠标还停在刘海/胶囊那一带时，不能算"离开"
        collapsedHitRect = islandFrame(expanded: false)
        clearReopenBlock(reason: "面板已展开")
        if activateApp {
            // 快捷键/菜单打开的：鼠标本来就不在面板上，不能按"鼠标离开"去收它
            stopHoverPoll()
        } else {
            startHoverPoll()
        }
        let target = islandFrame(expanded: true)
        dbg("expand -> \(Int(target.minX)),\(Int(target.minY)) \(Int(target.width))x\(Int(target.height)) activate=\(activateApp) 命中区=\(rectText(collapsedHitRect))")
        startMorph(to: target, expanding: true, choreographContent: !wasExpanded)
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        isExpanded = false
        panelIsExpandedForScan = false   // 收起就不再扫跨桌面窗口
        hiddenScanDidFinish = nil
        recorder?.cancelRecording()
        stopRefresh()
        // 录制中途收起：把原来能用的快捷键装回去
        if !hotKey.isRegistered {
            applyHotKey(code: hotKeyCode, mods: hotKeyMods, label: hotKeyLabel, quiet: true)
        }
        collapseWork?.cancel()
        collapseWork = nil
        stopHoverPoll()
        // 收起这一刻的折叠命中区，等下用来判断"鼠标是不是还赖在原地"
        collapsedHitRect = islandFrame(expanded: false)
        armReopenGuardIfNeeded()

        let target = islandFrame(expanded: false)
        dbg("collapse -> \(Int(target.minX)),\(Int(target.minY)) \(Int(target.width))x\(Int(target.height)) animated=\(animated)")
        if animated {
            startMorph(to: target, expanding: false)
        } else {
            // 自测/立刻收起：不走动画，直接把终点摆上
            morphDriver?.cancel()
            morphDriver = nil
            detail.alphaValue = 0
            expandedOnly.forEach { $0.alphaValue = 0 }
            capsuleStack.alphaValue = 1
            panel.setFrame(target, display: true)
            applyCollapsedAppearance()
        }
    }

    /// 展开/收起共用的"形变"动画：面板 frame、四角圆角、内容透明度挂在**同一条**弹簧曲线上，
    /// 一起起步、一起收尾。分开跑就是上一版那个样子 —— 面板先长完、内容再补上，一眼假。
    ///
    /// - `expanding == true`：从当前帧长到 `target`（胶囊内容让位、面板内容淡入）
    /// - `expanding == false`：缩回去（反过来）
    /// - `choreographContent == false`：只动 frame/形状，不碰内容透明度（本来就是展开态时用）
    private func startMorph(to target: NSRect, expanding: Bool, choreographContent: Bool = true) {
        let start = panel.frame
        let startShape = (shapeTopRadius, shapeBottomRadius)
        let endShape = expanding
            ? (Cfg.cornerRadius, Cfg.cornerRadius)
            : shapeRadii(for: collapsedStyle(on: currentScreen()))

        // 同一时刻只留一个动画：新的从"当前这一刻的 frame"接着走，
        // 所以"展开到一半又收起"是顺着当前速度拐回去，不会跳一下
        morphDriver?.cancel()
        let driver = SpringDriver(label: expanding ? "展开" : "收起",
                                  response: expanding ? Cfg.expandResponse : Cfg.collapseResponse,
                                  damping: Cfg.morphDamping) { [weak self] p, finished in
            guard let self else { return }
            // display: false —— 只标记"这一块要重绘"，交给本轮正常的显示周期。
            // 逐帧 display: true 会强制同步把十几张卡片重刷一遍，一帧十几毫秒，
            // 120Hz 上等于把主线程占满（帧间隔忽大忽小 = 肉眼看到的"不够顺"）
            self.panel.setFrame(Self.morphRect(from: start, to: target, progress: p), display: false)
            self.applyShape(topRadius: Self.lerp(startShape.0, endShape.0, p),
                            bottomRadius: Self.lerp(startShape.1, endShape.1, p))

            if choreographContent {
                // 内容跟着同一条曲线走：胶囊内容在前 40% 让位，面板内容在 8%~70% 之间淡入。
                // 两段有意重叠 —— 一先一后（上一版"长完再补"）就会被看出是两拍。
                let handover = min(1, max(0, p / 0.4))
                self.capsuleStack.alphaValue = expanding ? 1 - handover : handover
                let content = min(1, max(0, (p - 0.08) / 0.62))
                let contentAlpha = expanding ? content : 1 - content
                self.detail.alphaValue = contentAlpha
                self.expandedOnly.forEach { $0.alphaValue = contentAlpha }
            }

            if finished {
                self.panel.setFrame(target, display: true)
                self.morphDriver = nil
                // 缩回刘海/假刘海之后才隐去视觉：动画期间还得看得见它在缩
                if !expanding { self.applyCollapsedAppearance() }
            }
        }
        morphDriver = driver
        driver.start()
    }

    /// 面板按进度变形。**位置（左右 + 顶边）用夹在 1 的进度，尺寸用原始进度** ——
    /// 弹簧那一点点过冲只体现在"长得略大一点"上：顶边要是也跟着过冲，面板会越过
    /// 菜单栏/刘海下沿去压住系统菜单，左右也跟着过冲的话看着像在抖。
    private static func morphRect(from a: NSRect, to b: NSRect, progress t: Double) -> NSRect {
        let k = CGFloat(min(max(t, 0), 1))   // 位置：不许过头
        let g = CGFloat(t)                   // 尺寸：允许一点点过冲
        let x = a.minX + (b.minX - a.minX) * k
        let top = a.maxY + (b.maxY - a.maxY) * k
        let w = a.width + (b.width - a.width) * g
        let h = a.height + (b.height - a.height) * g
        return NSRect(x: x, y: top - h, width: w, height: h)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    /// 点卡片激活别的应用后自动收起（鼠标已经不在面板上了）
    func collapseAfterActivating(appName: String) {
        if isPinned {
            setStatus("已切到「\(appName)」· 面板已钉住，不收起")
        } else {
            setStatus("已切到「\(appName)」")
            collapse(animated: true)
        }
    }

    private func mouseEnteredIsland() {
        dbg("hover-enter")
        collapseWork?.cancel()
        collapseWork = nil
        guard !isExpanded, !isDraggingIsland else { return }
        guard UserDefaults.standard.bool(forKey: islandKey) else { return }
        guard !reopenBlocked else {
            dbg("hover-enter 被拦：鼠标还没离开命中区")
            return
        }
        // 进出事件在窗口动画期间会自己抖出来，用真实坐标核一遍
        guard islandFrame(expanded: false).contains(cursorLocation) else {
            dbg("hover-enter 忽略：坐标 \(cursorLocation) 不在命中区")
            return
        }
        expand(activateApp: false)
    }

    private func mouseExitedIsland() {
        dbg("hover-exit")
        guard isExpanded, !isPinned, !isDraggingIsland, !(recorder?.isRecording ?? false) else { return }
        checkCursorInsideExpanded()
    }

    // MARK: 悬停判定（只看坐标，不看控件进出事件）

    private func startHoverPoll() {
        stopHoverPoll()
        let timer = Timer(timeInterval: Cfg.hoverPollInterval, repeats: true) { [weak self] _ in
            self?.checkCursorInsideExpanded()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPollTimer = timer
    }

    private func stopHoverPoll() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    /// "还算在面板里"的范围 = 面板本身 ∪ 折叠命中区。
    /// 后半截是关键：有刘海的屏上，折叠命中区比展开面板的顶边还高出一截，
    /// 鼠标停在刘海正中最自然的位置时，展开面板根本够不着 —— 以前就是这么"来不及移进去就关了"。
    private func checkCursorInsideExpanded() {
        guard isExpanded, !isPinned, !isDraggingIsland, !(recorder?.isRecording ?? false) else { return }
        let inside = panel.frame.insetBy(dx: -1, dy: -1).contains(cursorLocation)
            || collapsedHitRect.contains(cursorLocation)
        if inside {
            if collapseWork != nil {
                collapseWork?.cancel()
                collapseWork = nil
                dbg("光标又回来了，取消收起")
            }
        } else if collapseWork == nil {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.collapse(animated: true) }
        collapseWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Cfg.collapseDelay, execute: item)
    }

    // MARK: 重开锁
    //
    // 收起时鼠标还停在命中区里（点了卡片切应用、按了快捷键、鼠标在原地没动），
    // 这时如果立刻允许重开，面板会"关了又开"来回抽风。所以加锁 —— 但解锁条件是
    // **鼠标离开**，不是"过 N 秒"：以前用固定 0.7 秒时间窗，鼠标一直在旁边蹭的
    // 时候就死活打不开，得等窗口过期，手感就是"连续 hover 打不开"。

    private func armReopenGuardIfNeeded() {
        guard collapsedHitRect.contains(cursorLocation) else {
            clearReopenBlock(reason: "鼠标不在命中区，无需加锁")
            return
        }
        reopenBlocked = true
        reopenGuardWork?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.clearReopenBlock(reason: "兜底超时") }
        reopenGuardWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Cfg.reopenGuardFallback, execute: item)
        startReopenWatch()
        dbg("重开加锁：鼠标还赖在命中区里")
    }

    private func startReopenWatch() {
        guard reopenWatchTimer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, self.reopenBlocked else { return }
            if !self.collapsedHitRect.contains(self.cursorLocation) {
                self.clearReopenBlock(reason: "鼠标已移开")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reopenWatchTimer = timer
    }

    private func clearReopenBlock(reason: String) {
        guard reopenBlocked || reopenWatchTimer != nil || reopenGuardWork != nil else { return }
        reopenBlocked = false
        reopenGuardWork?.cancel()
        reopenGuardWork = nil
        reopenWatchTimer?.invalidate()
        reopenWatchTimer = nil
        dbg("重开解锁（\(reason)）")
    }

    // MARK: 拖动灵动岛
    //
    // 折叠态整条都能按住拖；展开态则只认标题栏那条（卡片、按钮照常点）。
    // 位置按屏幕分别记住，下次开机还在那儿。

    /// 折叠态：胶囊钉死在屏幕顶部正中，不参与拖动（拖动只挪展开的面板）。
    /// 展开态：标题栏空白和标题那几块能拖，但**命中控件时一律让路** ——
    /// 标题栏是整条 596 宽的把手，右上角那排按钮（录制/置顶/刷新/收起）是它的子视图，
    /// 只按"是不是把手的子孙"判断的话，按钮会被 mouseDown 抢走 → 这就是"按钮点不动"的根因。
    private func shouldCaptureMouseForDrag(hitView: NSView) -> Bool {
        guard isExpanded else { return false }
        if Self.isInteractiveControl(hitView) { return false }
        return dragHandleViews.contains { hitView === $0 || hitView.isDescendant(of: $0) }
    }

    /// 命中的是不是"用户想点"的控件：看它自己以及祖先链上有没有按钮/录制器。
    /// 只认控件类型、不认视图层级，把手是新加的还是挪了位置都不影响判断。
    private static func isInteractiveControl(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is NSButton || v is HotKeyRecorder { return true }
            current = v.superview
        }
        return false
    }

    private func beginIslandDrag() {
        // 折叠态的胶囊不参与拖动 —— 它钉在屏幕顶部正中，拖动只挪展开的面板。
        // 正常交互里也轮不到这一步：鼠标一 hover 上来就展开（mouseEntered 是同步的），
        // 真按下时早就是展开态了。所以这里拦掉不影响"拖得动"。
        guard isExpanded else {
            dbg("drag begin 忽略：折叠态的胶囊不可拖")
            return
        }
        // 展开态也要能拖 —— 鼠标一 hover 上来面板就展开了，等按下时早就不是折叠态，
        // 这里要是还把展开态拦掉，用户就永远拖不动它（「面板拖不动」的根因就在这）。
        isDraggingIsland = true
        dragAccumulated = 0
        // 拖动按"绝对位置"走：记下这一刻面板的左上角，之后每步只往上加位移。
        // 不再拿"当前屏中心"当基准 —— 鼠标跨屏时那玩意儿会整块跳。
        let f = panel.frame
        draggedTopLeft = NSPoint(x: f.minX, y: f.maxY)
        collapseWork?.cancel()
        collapseWork = nil
        clearReopenBlock(reason: "开始拖动")
        dbg("drag begin screen=\(currentScreen().displayID)")
    }

    private func dragIslandBy(dx: CGFloat, dy: CGFloat) {
        guard isDraggingIsland else { return }
        dragAccumulated += abs(dx) + abs(dy)
        guard var topLeft = draggedTopLeft else { return }
        topLeft.x += dx
        topLeft.y += dy
        draggedTopLeft = topLeft
        // 拖的永远是展开的面板 —— 折叠态在 beginIslandDrag 那一步就被挡回去了。
        // 位置是绝对的，所以鼠标跨屏时这里不需要任何特殊处理，一路跟着走
        panel.setFrame(islandFrame(expanded: true), display: true)
    }

    private func endIslandDrag() {
        guard isDraggingIsland else { return }
        isDraggingIsland = false
        // 只是点了一下，没真拖动 —— 别弹提示
        guard dragAccumulated >= 3 else {
            dbg("drag: 累计位移只有 \(Int(dragAccumulated))pt，按「没拖」处理")
            return
        }
        // 这次挪开只管这一次：位置不缓存，下次打开仍在顶部正中
        setStatus("面板已挪开（位置不缓存，下次打开仍在初始位置）")
        dbg("drag end 临时位置=\(offsetText())（绝对坐标，跨屏不会跳）")
    }

    /// 把面板挪回初始位置（右键菜单项 / stdin `resetpos`）。
    /// 位置本来就不缓存，这里只是让"本次展开期间"的临时偏移提前归零。
    private func resetIslandPosition() {
        draggedTopLeft = nil
        panel.setFrame(islandFrame(expanded: isExpanded), display: true)
        applyCollapsedAppearance()
        setStatus("面板已回到初始位置")
        dbg("position reset（临时偏移归零）")
    }

    // MARK: 自测辅助（只有 CLOSEAPPS_SELFTEST / DEBUG 会用）

    /// 折叠命中区的中心：悬停展开打的就是这里
    private func capsuleCenter() -> NSPoint {
        let f = islandFrame(expanded: false)
        return NSPoint(x: f.midX, y: f.midY)
    }

    /// 一个"在折叠命中区里、但在展开面板之外"的点：有刘海时就是刘海正中最上面那一带，
    /// 也正是以前会把面板误判成"鼠标已离开"、害用户来不及移进去就关掉的位置
    private func hoverGraceProbe() -> NSPoint {
        let hit = islandFrame(expanded: false)
        let expanded = islandFrame(expanded: true)
        return NSPoint(x: hit.midX, y: max(hit.maxY - 4, expanded.maxY + 4))
    }

    /// 把一次拖动（按下 → 移动 → 松手）走完
    private func simulateDrag(dx: CGFloat, dy: CGFloat) {
        beginIslandDrag()
        dragIslandBy(dx: dx, dy: dy)
        endIslandDrag()
    }

    /// 展开态下标题栏右上角那排按钮必须"点得到"：命中测试要落在按钮上，
    /// 而且不能被判给拖动把手（以前整条标题栏都是把手，按钮一按就被 mouseDown 抢走）。
    private func probeHeaderHitTest() {
        guard isExpanded, let c = container, let pin = pinButton else {
            dbg("hit-test: 不在展开态或缺控件，跳过")
            return
        }
        let winPoint = pin.convert(NSPoint(x: pin.bounds.midX, y: pin.bounds.midY), to: nil)
        guard let hit = c.hitTest(winPoint) else {
            // 容器还停在展开动画中途的尺寸时，标题栏右上角那个点会落到容器外 —— 这不是按钮的问题
            let want = islandFrame(expanded: true).size
            dbg("hit-test: 置顶按钮处没命中任何视图（面板 \(Int(panel.frame.width))x\(Int(panel.frame.height))，"
                + "展开应为 \(Int(want.width))x\(Int(want.height)) → 多半是动画还没走完，跳过）")
            return
        }
        let captured = shouldCaptureMouseForDrag(hitView: hit)
        dbg("hit-test: 置顶按钮 → \(type(of: hit))｜拖动接管=\(captured ? "是 ✗ 按钮会被拖走" : "否 ✓ 按钮可点")")
    }

    /// ★「跨屏拖动不跳」的回归断言。
    ///
    /// 老实现把位置存成"相对当前屏中心的偏移"，而"当前屏"看的是鼠标在哪块屏：
    /// 鼠标一跨到另一块屏，基准 screen.midX 直接换一个值，面板就瞬间平移到新屏的
    /// 对应位置（用户原话：在大屏右侧拖到第二屏，就闪到第二屏的右侧去了）。
    /// 现在位置是绝对坐标，跨屏只应该跟着鼠标走那么一小步。
    private func probeCrossScreenDrag() {
        let screens = NSScreen.screens
        guard screens.count >= 2 else {
            dbg("跨屏拖动: 本机只有 \(screens.count) 块屏，这条断言不适用（跳过）")
            return
        }
        let a = screens[0], b = screens[1]
        fakeCursor = NSPoint(x: a.frame.midX, y: a.frame.midY)
        beginIslandDrag()
        let before = panel.frame
        let stepX: CGFloat = 6, stepY: CGFloat = -4
        // 光标一步跨到另一块屏上，而位移只走了这么一点
        fakeCursor = NSPoint(x: b.frame.midX, y: b.frame.midY)
        dragIslandBy(dx: stepX, dy: stepY)
        let after = panel.frame
        endIslandDrag()
        let dx = after.minX - before.minX, dy = after.minY - before.minY
        let midGap = b.frame.midX - a.frame.midX
        let ok = abs(dx - stepX) < 1.5 && abs(dy - stepY) < 1.5
        dbg("跨屏拖动: \(a.localizedName)→\(b.localizedName) 两屏中线差=\(Int(midGap))pt｜"
            + "面板位移=\(Int(dx)),\(Int(dy)) 期望=\(Int(stepX)),\(Int(stepY)) "
            + (ok ? "✓ 只跟着鼠标走，没被另一块屏拽走" : "✗ 跨屏瞬间跳了"))
        // 光标放回面板自己身上：后面的步骤（收起/重开）就按面板所在的那块屏继续
        fakeCursor = NSPoint(x: after.midX, y: after.midY)
    }

    /// 连采若干帧，量一下展开动画顺不顺（自测用）。
    /// 顺滑 = 相邻两帧的位移都不大、也不忽大忽小；卡顿会表现为某一帧突然挪一大截。
    private func trackMorphMotion(_ tag: String) {
        morphTrack = []
        // ⚠️ 目标帧在"开跑那一刻"就定下来。收尾时再算一次是不可靠的：`islandFrame` 认的是
        // `currentScreen()`（看注入的光标落在哪块屏，全都不在就退到 NSScreen.main），
        // 采样窗口里只要这个基准变一次，就会拿另一块屏的目标去判这块屏的末帧，报假红。
        morphTarget = islandFrame(expanded: true)
        let steps = 15
        let gap = 0.026
        for i in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i + 1) * gap) { [weak self] in
                guard let self else { return }
                self.morphTrack.append(self.panel.frame)
                if i == steps - 1 { self.reportMorphMotion(tag) }
            }
        }
    }

    private func reportMorphMotion(_ tag: String) {
        guard morphTrack.count >= 3, let target = morphTarget else {
            dbg("morph[\(tag)]: 采样不足，跳过")
            return
        }
        var deltas: [CGFloat] = []
        for i in 1..<morphTrack.count {
            let a = morphTrack[i - 1], b = morphTrack[i]
            deltas.append(abs(b.midX - a.midX) + abs(b.midY - a.midY))
        }
        let maxDelta = deltas.max() ?? 0
        let avg = deltas.reduce(0, +) / CGFloat(deltas.count)
        let maxHeight = morphTrack.map(\.height).max() ?? 0
        let overshoot = max(0, maxHeight - target.height)
        let last = morphTrack[morphTrack.count - 1]
        let settled = abs(last.maxY - target.maxY) < 2 && abs(last.height - target.height) < 2
        dbg("morph[\(tag)]: 采样\(morphTrack.count)点/间隔26ms｜相邻位移 最大=\(Int(maxDelta))pt 平均=\(Int(avg))pt｜"
            + "过冲=\(Int(overshoot))pt（目标高\(Int(target.height))）｜末帧=\(rectText(last)) 目标=\(rectText(target)) "
            + "差=\(Int(last.maxY - target.maxY))pt/\(Int(last.height - target.height))pt "
            + (settled ? "✓ 已落到目标" : "✗ 还没走完/没落准"))
    }

    /// 折叠态的胶囊必须钉在屏幕顶部正中：位置只由当前屏决定，任何临时偏移都不准影响它。
    private func probeCapsulePinned() {
        let screen = currentScreen()
        let frame = islandFrame(expanded: false)
        let expectX = round(screen.frame.midX - frame.width / 2)
        let pinned = abs(frame.minX - expectX) < 1.5
        dbg("胶囊定位: 拖动位置=\(offsetText())｜实际x=\(Int(frame.minX)) 期望x=\(Int(expectX)) "
            + (pinned ? "✓ 没被拖走" : "✗ 跟着面板跑了"))
    }

    /// 开机启动的**只读**探测。
    ///
    /// ⚠️ 以前自测里直接调 `menuToggleLoginItem()` 开关一遍 —— 而 `SMAppService.mainApp`
    /// 注册的是"**正在跑的那份 bundle**"。于是每跑一次自测，开机项就被重新注册成当时那份副本
    /// （实测被挂到了工作树里的开发副本上，开机拉起的是开发版，不是 /Applications 那份）。
    /// 自测只该看，不该动用户的系统设置。
    private func probeLoginItem() {
        dbg("开机启动（只读，不改动）: 已启用=\(LoginItem.isEnabled) 待批准=\(LoginItem.needsApproval)"
            + "｜当前 bundle=\(Bundle.main.bundlePath)")
    }

    /// ★ 折叠条形状的回归断言：两层裁剪（layer 圆角 + 毛玻璃遮罩）都得是
    /// `0 0 16px 16px`（上缘直角、下缘 16）。看得见的胶囊一旦变成整圈圆角的"药丸"，
    /// 用户一眼就看出来不对 —— 这条就是盯着它的。
    private func probeCapsuleShape() {
        let screen = currentScreen()
        let style = collapsedStyle(on: screen)
        let want = shapeRadii(for: style)
        let layerR = container.layer?.cornerRadius ?? -1
        let topOK = abs(shapeTopRadius - want.top) < 0.5
        let bottomOK = abs(shapeBottomRadius - want.bottom) < 0.5
        let layerOK = abs(layerR - min(want.top, want.bottom)) < 0.5
        let hidden = style == .hiddenInNotch
        let maskText = fullSizeMask != nil && maskUsedFullSize ? "真尺寸图" : "小图拉伸"
        dbg("折叠条形状: 样式=\(style)\(hidden ? "（隐形，形状无所谓）" : "")"
            + "｜目标=上\(Int(want.top))/下\(Int(want.bottom)) 生效=上\(Int(shapeTopRadius))/下\(Int(shapeBottomRadius))"
            + " layer圆角=\(Int(layerR)) 遮罩=\(maskText)"
            + " 尺寸=\(Int(panel.frame.width))x\(Int(panel.frame.height))"
            + " " + (topOK && bottomOK && layerOK
                     ? (want.top < 0.5 ? "✓ 上缘直角 + 下缘 \(Int(want.bottom)) 圆角（0 0 16 16）"
                                       : "✓ 四角都是 \(Int(want.top)) 圆角（隐形态，形状看不见）")
                     : "✗ 形状不对"))
    }

    /// ★ 「软件自己去看一眼有没有新版」的回归断言：版本比较、JSON 解析、横幅显示。
    ///
    /// **不联网** —— 自测不该依赖网络，否则今天网不好就红一片，分不清是代码坏了还是网坏了。
    /// 真请求那一步单独手工验（`printf 'update\\n' | CLOSEAPPS_DEBUG=1 ...`）。
    private func probeUpdateCheck() {
        // 1.10 > 1.9 这条是关键用例：用字符串比会判成 false
        let cases: [(String, String, Bool)] = [
            ("1.1.1", "1.1", true),
            ("1.1", "1.1", false),
            ("1.1", "1.1.1", false),
            ("1.10", "1.9", true),
            ("2.0", "1.9.9", true),
            ("1.9.9", "2.0", false),
        ]
        let wrong = cases.filter { versionIsNewer($0.0, than: $0.1) != $0.2 }
        let versionOK = wrong.isEmpty

        let sample = Data(#"{"tag_name":"v9.9.9","html_url":"https://github.com/liulao-space/close-app/releases/tag/v9.9.9"}"#.utf8)
        let parsed = parseUpdateFeed(sample)
        let parseOK = parsed?.version == "9.9.9" && (parsed?.url.absoluteString.hasSuffix("/v9.9.9") ?? false)
        let garbageOK = parseUpdateFeed(Data("not json at all".utf8)) == nil

        simulateUpdateBanner("9.9.9")
        let shownOK = !updateBanner.isHidden && updateBannerHeight.constant > 0
        hideUpdateBanner()
        let hiddenOK = updateBanner.isHidden && updateBannerHeight.constant == 0

        let ok = versionOK && parseOK && garbageOK && shownOK && hiddenOK
        dbg("更新检查: 当前版本=\(currentVersion) 版本比较=\(versionOK ? "6 例全过" : "✗ \(wrong.count) 例判错")"
            + " 解析=\(parseOK ? "✓" : "✗") 坏数据不崩=\(garbageOK ? "✓" : "✗")"
            + " 横幅显示=\(shownOK ? "✓" : "✗") 收起=\(hiddenOK ? "✓" : "✗")"
            + " 自动检查=\(checkUpdatesEnabled ? "开" : "关")"
            + " " + (ok ? "✓ 逻辑与横幅都对（真网络请求不在自测里跑）" : "✗ 有问题"))
    }

    /// ★ 滚动条宽度的回归断言。
    ///
    /// 宽度是 `NSScroller` 的**类方法**算的，所以"换了子类"还不算数 —— 得看 NSScrollView
    /// 是不是真的按子类给的宽度去布局。面板自己的滚动视图会随内容多少决定显不显示滚动条
    /// （内容不长时它是隐藏的、frame 为 0，量了也白量），所以这里当场手搓一个**内容一定超高**
    /// 的滚动视图把滚动条逼出来，量它的实际占宽。
    private func probeScroller() {
        let style = NSScroller.preferredScrollerStyle          // 跟随系统设置（"总是显示"= 传统样式）
        let sysW = NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
        let probe = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        probe.hasVerticalScroller = true
        probe.autohidesScrollers = false
        probe.verticalScroller = ThinScroller()
        probe.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 900))
        probe.layoutSubtreeIfNeeded()
        let kind = probe.verticalScroller.map { String(describing: type(of: $0)) } ?? "无"
        let width = probe.verticalScroller.map { $0.frame.width } ?? -1
        let ok = width > 0 && width <= ThinScroller.width + 1 && width < sysW
        dbg("滚动条: 类型=\(kind) 系统=\(style == .overlay ? "浮动" : "传统")样式 默认 \(Int(sysW))pt"
            + " → 实测布局 \(Int(width))pt "
            + (ok ? "✓ 比系统细" : "✗ 宽度没生效"))
    }

    /// ★ 「无刘海屏那枚假刘海 = 0 0 16 16」的回归断言。
    ///
    /// 不靠"鼠标此刻在哪块屏"，自己找一块没有刘海的屏，把假光标挪过去、按换屏那套动作重摆一次
    /// （和 `followMouseScreen` 同一条路径），再量形状：贴屏幕顶沿、上缘直角、下缘 16 圆角，
    /// 而且用的是真尺寸遮罩（不是小图拉伸）。
    private func probeFakeNotchShape() {
        guard let screen = NSScreen.screens.first(where: { $0.notchRect == nil }) else {
            dbg("假刘海形状: 本机每块屏都有刘海，没有这一态（跳过）")
            return
        }
        fakeCursor = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 4)
        panel.setFrame(islandFrame(expanded: false), display: false)
        applyCollapsedAppearance()
        let style = collapsedStyle(on: screen)
        let want = shapeRadii(for: style)
        let frame = panel.frame
        let bar = capsuleBarHeight(on: screen)
        let topAligned = abs(frame.maxY - screen.frame.maxY) < 1.5
        let sizeOK = abs(frame.width - Cfg.capsuleWidth) < 1.5 && abs(frame.height - bar) < 1.5
        let shapeOK = abs(shapeTopRadius - want.top) < 0.5 && abs(shapeBottomRadius - want.bottom) < 0.5
        let layerOK = abs((container.layer?.cornerRadius ?? -1) - min(want.top, want.bottom)) < 0.5
        let ok = style == .fakeNotch && topAligned && sizeOK && shapeOK && layerOK && maskUsedFullSize
        dbg("假刘海形状: 屏=\(screen.localizedName) 样式=\(style)"
            + " 条=\(Int(frame.width))x\(Int(frame.height))（菜单栏高 \(Int(bar))）"
            + " 顶边贴屏顶=\(topAligned) 上缘=\(Int(shapeTopRadius)) 下缘=\(Int(shapeBottomRadius))"
            + " layer圆角=\(Int(container.layer?.cornerRadius ?? -1))"
            + " 遮罩=\(maskUsedFullSize ? "真尺寸图" : "小图拉伸")"
            + " " + (ok ? "✓ 上缘直角 + 下缘 16 圆角" : "✗ 形状/位置不对"))
    }

    /// ★ 「打开就回初始位置」的回归断言：拖开 → 收起 → 再打开，
    /// 位置必须回到默认（临时偏移归零、x 居中、顶边贴菜单栏/刘海下沿）。
    ///
    /// ⚠️ 判据要用 `islandFrame`，**不能拿 `panel.frame` 比** —— 展开是弹簧动画（约 0.4s），
    /// 读到的很可能是途中的值，白得一个假阴性（第一版就是这么写的）。
    private func probeExpandResetsPosition() {
        let screen = currentScreen()
        let target = islandFrame(expanded: true)
        let baseTop = screen.notchRect?.minY ?? screen.visibleFrame.maxY
        let centered = abs(target.midX - screen.frame.midX) < 1.5
        let topAligned = abs(target.maxY - baseTop) < 1.5
        let noOffset = draggedTopLeft == nil
        let ok = centered && topAligned && noOffset
        dbg("重开归位: 拖动位置=\(offsetText())｜目标框=\(rectText(target)) 居中=\(centered) 顶边贴栏=\(topAligned) "
            + (ok ? "✓ 回到初始位置" : "✗ 还带着旧位置"))
    }

    /// 双屏时胶囊跟着鼠标走：折叠态每 1 秒看一眼鼠标在哪块屏，跨屏了就挪过去
    private func followMouseScreen() {
        guard !isExpanded, panel.isVisible else { return }
        guard UserDefaults.standard.bool(forKey: islandKey) else { return }
        let id = currentScreen().displayID
        guard id != lastScreenID else { return }
        lastScreenID = id
        panel.setFrame(islandFrame(expanded: false), display: true)
        applyCollapsedAppearance()   // 换屏了：目标屏可能有/没有刘海，视觉状态跟着切
        dbg("island -> 屏幕 \(id) 有刘海=\(currentScreen().notchRect != nil)")
    }

    private func applyIslandVisibility() {
        let show = UserDefaults.standard.bool(forKey: islandKey)
        if show {
            panel.setFrame(islandFrame(expanded: isExpanded), display: false)
            panel.orderFront(nil)
            applyCollapsedAppearance()
        } else if !isExpanded {
            panel.orderOut(nil)
        }
    }

    /// 折叠态该长什么样。屏幕有刘海且开关开着 → 彻底隐去视觉（阴影必须一起关：
    /// 面板藏在刘海后面，阴影会投到刘海下面露馅）；没有刘海的屏 → 做成一枚"假刘海"。
    private func applyCollapsedAppearance() {
        guard !isExpanded else { return }
        // 折叠态不占键盘焦点：拖一下胶囊会让面板变成 key window，
        // 之后用户接着打字就被这枚胶囊吞了。折叠着的时候把焦点还回去。
        if panel.isKeyWindow { panel.resignKey() }
        let screen = currentScreen()
        let style = collapsedStyle(on: screen)
        let hidden = style == .hiddenInNotch
        container?.alphaValue = hidden ? 0 : 1
        panel?.hasShadow = !hidden
        applyCapsuleShape(style)
        dbg("collapsed appearance: 样式=\(style) 隐身=\(hidden) 条高=\(Int(capsuleBarHeight(on: screen)))")
    }

    /// 当前实际生效的上下圆角。展开动画逐帧改的就是它，也是下一个动画的起点
    private var shapeTopRadius: CGFloat = Cfg.cornerRadius
    private var shapeBottomRadius: CGFloat = Cfg.cornerRadius
    /// 上一次真正喂给遮罩的圆角：差得不多就不重做遮罩
    private var maskTopRadius: CGFloat = -1
    private var maskBottomRadius: CGFloat = -1
    /// 上一次用的是不是"真尺寸出图"那张遮罩（见 applyShape）
    private var maskUsedFullSize = false
    /// 真尺寸遮罩的缓存（key = 尺寸@刻度+圆角）
    private var fullSizeMaskKey = ""
    private var fullSizeMask: NSImage?

    /// 某个折叠样式的四角半径（上, 下）。
    ///
    /// **折叠态但凡是看得见的，都是 `border-radius: 0 0 16px 16px`** —— 上缘两个直角、
    /// 下缘两角 16 圆角：看上去就是"从屏幕顶上垂下来的一整块"。
    /// 无刘海屏那枚贴屏幕顶沿；有刘海屏关掉「折叠时藏进刘海」时那枚胶囊吊在刘海正下方，
    /// 上缘直角正好跟刘海接上（胶囊 176 宽、刘海 185 宽，宽度也基本对得上）。
    /// 藏进刘海那一态是隐形的，圆角取多少都看不见，跟面板的 18 走。
    private func shapeRadii(for style: CapsuleStyle) -> (top: CGFloat, bottom: CGFloat) {
        switch style {
        case .fakeNotch, .plain: return (0, Cfg.fakeNotchRadius)
        case .hiddenInNotch: return (Cfg.cornerRadius, Cfg.cornerRadius)
        }
    }

    /// 折叠条的形状：无刘海屏那枚是"假刘海"（上缘直角、下缘两角圆角，见 perCornerPath），
    /// 其余是圆角胶囊。裁剪做了两层（layer 圆角 + 毛玻璃 maskImage），所以两边都要跟着切。
    private func applyCapsuleShape(_ style: CapsuleStyle) {
        let r = shapeRadii(for: style)
        applyShape(topRadius: r.top, bottomRadius: r.bottom)
        // 折叠时把头部压到"条高"，胶囊里的图标文字才垂直居中
        headerHeightConstraint?.constant = style == .fakeNotch
            ? capsuleBarHeight(on: currentScreen())
            : Cfg.headerHeight
    }

    /// 把四角半径落到两层裁剪上（layer 圆角 + 毛玻璃遮罩）。展开动画会逐帧调它，
    /// 所以这里只做"把当前值摆上去"，不判断状态、不做别的事。
    private func applyShape(topRadius: CGFloat, bottomRadius: CGFloat) {
        shapeTopRadius = topRadius
        shapeBottomRadius = bottomRadius
        // layer 的圆角是四角统一的，取小的那个顶事（大半径那两个角由遮罩负责）
        container?.layer?.cornerRadius = min(topRadius, bottomRadius)
        // 折叠态那枚"上缘直角 + 下缘圆角"改用**真尺寸出图**：圆角 16 而条高只有 24~36pt，
        // 小图 + capInsets 三段拉伸在这种又矮又扁的条上会差个一两像素，而这一帧是静止的、
        // 只画一次，没理由去省。动画中间帧照旧用小图（形状在动，逐帧重出真尺寸图没必要）。
        let fullSize = topRadius < 0.25 && bottomRadius > 1
        let modeChanged = fullSize != maskUsedFullSize
        let radiiChanged = abs(topRadius - maskTopRadius) > 0.5 || abs(bottomRadius - maskBottomRadius) > 0.5
        // 圆角没明显变化就别重做遮罩：maskImage 一换，毛玻璃那块要重算。
        // 有刘海的主屏上圆角一直是 18，这条判断完全不会触发，逐帧开销为零。
        guard modeChanged || radiiChanged else { return }
        maskTopRadius = topRadius
        maskBottomRadius = bottomRadius
        maskUsedFullSize = fullSize
        if fullSize {
            let size = panel?.frame.size ?? Cfg.capsuleSize
            let scale = currentScreen().backingScaleFactor
            let key = "\(Int(size.width))x\(Int(size.height))@\(scale)r\(Int(bottomRadius.rounded()))"
            if key != fullSizeMaskKey || fullSizeMask == nil {
                fullSizeMaskKey = key
                fullSizeMask = Self.notchMask(size: size, radius: bottomRadius, scale: scale)
            }
            blur?.maskImage = fullSizeMask
        } else {
            blur?.maskImage = Self.panelMask(topRadius: topRadius, bottomRadius: bottomRadius)
        }
    }

    /// 折叠时是否藏进刘海（默认开）
    private var hidesInNotch: Bool {
        UserDefaults.standard.object(forKey: hidesInNotchKey) as? Bool ?? true
    }

    @objc private func screenParametersChanged() {
        guard panel != nil else { return }
        panel.setFrame(islandFrame(expanded: isExpanded), display: true)
        applyCollapsedAppearance()
    }

    // MARK: 快捷键

    private func setupHotKey() {
        hotKey.onTrigger = { [weak self] in self?.toggleFromKeyboard() }

        let d = UserDefaults.standard
        hotKeyCode = d.object(forKey: hotKeyCodeKey) as? Int ?? Int(kVK_ANSI_K)
        hotKeyMods = d.object(forKey: hotKeyModsKey) as? Int ?? Int(cmdKey | optionKey)
        hotKeyLabel = d.string(forKey: hotKeyLabelKey) ?? "⌥⌘K"
        recorder.label = hotKeyLabel
        applyHotKey(code: hotKeyCode, mods: hotKeyMods, label: hotKeyLabel, quiet: true)
    }

    private func applyHotKey(code: Int, mods: Int, label: String, quiet: Bool = false) {
        let previous = (hotKeyCode, hotKeyMods, hotKeyLabel)

        if code == 0 || mods == 0 {
            hotKey.unregister()
            hotKeyCode = 0
            hotKeyMods = 0
            hotKeyLabel = "无"
            recorder.label = hotKeyLabel
            persistHotKey()
            if !quiet { setStatus("已清除全局快捷键") }
            return
        }

        if hotKey.register(keyCode: UInt32(code), modifiers: UInt32(mods)) {
            dbg("hotkey registered: \(label) (code=\(code) mods=\(mods))")
            hotKeyCode = code
            hotKeyMods = mods
            hotKeyLabel = label
            recorder.label = label
            persistHotKey()
            if !quiet { setStatus("快捷键已改为 \(label)") }
        } else {
            // 被别的应用占了：还原上一次能用的
            let restored = hotKey.register(keyCode: UInt32(previous.0), modifiers: UInt32(previous.1))
            hotKeyCode = previous.0
            hotKeyMods = previous.1
            hotKeyLabel = previous.2
            recorder.label = hotKeyLabel
            persistHotKey()
            setStatus(restored ? "✗ \(label) 被其他应用占用，已还原为 \(hotKeyLabel)" : "✗ 快捷键注册失败")
            setCapsuleNotice("✗ \(label) 被占用")
        }
    }

    private func persistHotKey() {
        let d = UserDefaults.standard
        d.set(hotKeyCode, forKey: hotKeyCodeKey)
        d.set(hotKeyMods, forKey: hotKeyModsKey)
        d.set(hotKeyLabel, forKey: hotKeyLabelKey)
    }

    private func beginRecordingHotKey() {
        collapseWork?.cancel()
        collapseWork = nil
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        hotKey.unregister()
        recorder.beginRecording()
        setStatus("按下新的组合键 · Esc 取消 · Delete 清除")
    }

    private func finishRecordingHotKey() {
        // 录制取消或结束后没注册上，就把原来的装回去
        if !hotKey.isRegistered {
            applyHotKey(code: hotKeyCode, mods: hotKeyMods, label: hotKeyLabel, quiet: true)
        }
    }

    @objc private func menuEditHotKey() {
        expand(activateApp: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.beginRecordingHotKey()
        }
    }

    @objc func toggleFromKeyboard() {
        if isExpanded {
            collapse(animated: true)
        } else {
            clearReopenBlock(reason: "快捷键打开")
            expand(activateApp: true)
        }
    }

    // MARK: 菜单动作

    @objc private func menuToggleIsland() {
        let d = UserDefaults.standard
        let next = !d.bool(forKey: islandKey)
        d.set(next, forKey: islandKey)
        applyIslandVisibility()
        if next {
            setStatus("灵动岛胶囊已显示（鼠标移上去展开面板）")
        } else {
            setStatus("灵动岛胶囊已隐藏，用菜单栏图标或快捷键打开")
        }
    }

    @objc private func menuResetIslandPosition() {
        resetIslandPosition()
    }

    @objc private func menuToggleHidesInNotch() {
        let next = !hidesInNotch
        UserDefaults.standard.set(next, forKey: hidesInNotchKey)
        if !isExpanded {
            panel.setFrame(islandFrame(expanded: false), display: true)
        }
        applyCollapsedAppearance()
        setStatus(next ? "折叠时藏进刘海（鼠标移到刘海就会展开）" : "折叠时显示胶囊")
    }

    @objc private func menuToggleLoginItem() {
        let next = !LoginItem.isEnabled
        if let error = LoginItem.setEnabled(next) {
            setStatus("✗ 开机启动设置失败：\(error)")
            if LoginItem.needsApproval {
                setStatus("请在「系统设置 › 通用 › 登录项」里允许 CloseApps")
            }
            return
        }
        setStatus(next ? "✓ 已开启开机自动启动" : "已关闭开机自动启动")
    }

    @objc private func togglePin() {
        isPinned.toggle()
        UserDefaults.standard.set(isPinned, forKey: pinKey)
        applyPinAppearance()
        setStatus(isPinned ? "✓ 面板已钉住（鼠标移开也不收起）" : "已取消钉住")
    }

    private func applyPinAppearance() {
        guard pinButton != nil else { return }
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: "钉住")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func collapseNow() {
        collapse(animated: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 数据

    private var visibleApps: [NSRunningApplication] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let all = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != myPid
        }
        // ⚠️ 必须自己排序：`runningApplications` 的返回顺序**不保证稳定**，
        // 不排的话每 2 秒一次的自动刷新会让卡片莫名其妙地跳位置
        // （踩过：连查三次拿到的顺序都不一样，导出演示素材时"少了的那几个"完全对不上）。
        // 按本地化名称排，中文走拼音、英文走字母、数字按自然序。
        .sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
        if debugAppDrop > 0 { return Array(all.dropFirst(debugAppDrop)) }
        return all
    }

    /// 折叠态：只更新数量与授权角标，不碰窗口列表（省电）
    private func updateCounts() {
        appCount = visibleApps.count
        let trusted = axTrusted()
        titleLabel.stringValue = "正在运行的应用（\(appCount)）"
        capsuleLabel.stringValue = "\(appCount) 个应用"
        capsuleBadge.isHidden = trusted
        authBanner.isHidden = trusted
        authBannerHeight.constant = trusted ? 0 : 18
    }

    private func refreshLightweight() {
        if isExpanded {
            reload()
        } else {
            updateCounts()
        }
    }

    private func setCapsuleNotice(_ text: String) {
        guard capsuleLabel != nil else { return }
        capsuleNoticeWork?.cancel()
        capsuleLabel.stringValue = text
        let item = DispatchWorkItem { [weak self] in self?.updateCounts() }
        capsuleNoticeWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    /// 动画期间要跑的重载：AX 查询是**同步 IPC**，某个应用不响应时一卡就是几百毫秒，
    /// 正巧落在展开那 0.3s 里，画面就会明显顿一下 —— 直接推到动画结束再跑。
    /// 展开时内容刚刷过一遍，晚这 0.3s 完全看不出来。
    func reload(force: Bool = false) {
        guard morphDriver == nil else {
            dbg("reload 推迟：动画进行中（AX 查询会占住主线程）")
            deferredReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.deferredReload = nil
                self.reload(force: force)      // 还在动画中就再等一会儿
            }
            deferredReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
            return
        }
        let started = CACurrentMediaTime()
        reloadCounter += 1
        let trusted = axTrusted()
        appCount = visibleApps.count

        let current = visibleApps.sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
        var windowsByPid: [pid_t: [WinInfo]] = [:]
        if trusted {
            pruneHiddenWindowCache(keeping: Set(current.map { $0.processIdentifier }))
            // 系统窗口列表整轮只取一次给所有应用共用（每个应用各取一次要多花十几毫秒）
            let cgCandidates = cgCandidateWindowIDs()
            for app in current {
                windowsByPid[app.processIdentifier] = axWindows(for: app,
                                                                cgCandidates: cgCandidates[app.processIdentifier] ?? [])
            }
        }

        titleLabel.stringValue = "正在运行的应用（\(current.count)）"
        capsuleLabel.stringValue = "\(current.count) 个应用"
        capsuleBadge.isHidden = trusted
        authBanner.isHidden = trusted
        authBannerHeight.constant = trusted ? 0 : 18

        // 签名：进程集合 + 窗口数量；数量没变时跳过重建（每 10 秒强制重建一次以刷新标题）
        let signature = current.map { "\($0.processIdentifier)|\(windowsByPid[$0.processIdentifier]?.count ?? 0)" }
        let periodic = reloadCounter % 5 == 0
        if !force && !periodic && signature == lastSignature { return }
        lastSignature = signature
        apps = current

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
        // 调试：一眼看出"这次到底有没有认出多窗口应用"——
        // 面板上少了窗口卡时，先来这里看是 AX 没查到，还是查到了但没建卡。
        if debugEnabled {
            let multi = windowsByPid.filter { $0.value.count >= 2 }
                .map { "\($0.key):\($0.value.count)" }.sorted()
            dbg("reload: 应用=\(current.count) 多窗口=[\(multi.joined(separator: ","))] 卡片=\(cards.count)")
        }
        let cost = (CACurrentMediaTime() - started) * 1000
        if cost > 20 {
            dbg("reload 用时=\(Int(cost))ms（\(apps.count) 个应用，开辅助功能后这里会明显变慢）")
        }
    }

    private func startRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Cfg.refreshInterval, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
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

    // MARK: 检查更新

    /// 当前版本，取自 Info.plist，跟 release tag 对得上
    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    private var checkUpdatesEnabled: Bool {
        UserDefaults.standard.object(forKey: checkUpdatesKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: checkUpdatesKey)
    }

    /// 按 `.` 分段逐位比数字。
    ///
    /// ⚠️ 千万别图省事用字符串比：字典序里 `"1.10" < "1.9"`（'1' 比 '9' 小），
    /// 版本号就会卡在 1.9 再也涨不到 1.10 —— 这种 bug 要等到真发 1.10 那天才炸。
    private func versionIsNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 从 GitHub `releases/latest` 的响应里取出（版本号, 页面地址）。
    /// 抽成独立函数是为了自测能喂假 JSON —— 不用联网也能验解析。
    private func parseUpdateFeed(_ data: Data) -> (version: String, url: URL)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let link = (obj["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: Cfg.releasePageURL)
        guard let link else { return nil }
        return (version, link)
    }

    /// 启动后延迟查一次，之后每 6 小时一次。
    private func scheduleUpdateCheck() {
        guard checkUpdatesEnabled else {
            dbg("更新检查: 用户关掉了自动检查，跳过")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Cfg.updateCheckDelay) { [weak self] in
            self?.checkForUpdate()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: Cfg.updateCheckInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    /// `manual = true`（菜单点的）：成功失败都给一句回话。
    /// 自动那次全程静默 —— 查不到就当没这回事，绝不打扰。
    private func checkForUpdate(manual: Bool = false) {
        guard let url = URL(string: Cfg.updateFeedURL) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // GitHub 要求带 User-Agent；顺便把自家版本报过去，人家也是这么干的
        req.setValue("CloseApps/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUpdateCheckKey)
        if manual { setStatus("正在检查更新…") }
        dbg("更新检查: 发起请求（\(manual ? "手动" : "自动")）\(url.absoluteString)")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            let parsed = data.flatMap { self.parseUpdateFeed($0) }
            DispatchQueue.main.async {
                self.applyUpdateResult(parsed, error: error, manual: manual)
            }
        }.resume()
    }

    private func applyUpdateResult(_ parsed: (version: String, url: URL)?, error: Error?, manual: Bool) {
        guard let parsed else {
            dbg("更新检查: 没拿到结果（\(error?.localizedDescription ?? "响应里没有 tag_name")）")
            if manual { setStatus("检查更新失败，稍后再试") }
            return
        }
        if versionIsNewer(parsed.version, than: currentVersion) {
            dbg("更新检查: 有新版本 \(parsed.version)（当前 \(currentVersion)）→ \(parsed.url.absoluteString)")
            showAvailableUpdate(version: parsed.version, url: parsed.url)
            if manual { setStatus("发现新版本 \(parsed.version)") }
        } else {
            dbg("更新检查: 已是最新（远端 \(parsed.version) / 当前 \(currentVersion)）")
            hideUpdateBanner()
            if manual { setStatus("已是最新版本 \(currentVersion)") }
        }
    }

    /// 横幅一出现就常驻（不是弹窗，只有用户主动打开面板才看得见，所以不需要限频）；
    /// 真正要限频的是**网络请求**，那个由 `updateCheckInterval` 管。
    private func showAvailableUpdate(version: String, url: URL) {
        availableUpdate = (version, url)
        updateBanner.title = "新版本 \(version) 可用，点这里查看 →"
        updateBanner.isHidden = false
        updateBannerHeight.constant = 18
    }

    private func hideUpdateBanner() {
        availableUpdate = nil
        updateBanner.isHidden = true
        updateBannerHeight.constant = 0
    }

    @objc private func openUpdatePage() {
        guard let update = availableUpdate else { return }
        // 优先走 Sparkle 应用内升级（下载→替换→重启）；
        // updater 不可用时退回浏览器打开发布页
        if let controller = updaterController {
            dbg("更新检查: 走 Sparkle 应用内升级")
            controller.checkForUpdates(nil)
            return
        }
        NSWorkspace.shared.open(update.url)
        dbg("更新检查: 已在浏览器打开 \(update.url.absoluteString)")
    }

    @objc private func menuCheckUpdate() { checkForUpdate(manual: true) }

    @objc private func menuToggleCheckUpdates() {
        let now = !checkUpdatesEnabled
        UserDefaults.standard.set(now, forKey: checkUpdatesKey)
        updateTimer?.invalidate()
        updateTimer = nil
        if now {
            scheduleUpdateCheck()
            setStatus("已开启自动检查更新")
        } else {
            setStatus("已关闭自动检查更新")
        }
        dbg("更新检查: 自动检查 -> \(now ? "开" : "关")")
    }

    /// 仅调试（stdin `fakeupdate 9.9.9`）：不联网也能把横幅逼出来看长相
    private func simulateUpdateBanner(_ version: String) {
        guard !version.isEmpty, let url = URL(string: Cfg.releasePageURL) else { return }
        showAvailableUpdate(version: version, url: url)
        dbg("更新检查: 假数据置入横幅 \(version)（高=\(updateBannerHeight.constant) 隐藏=\(updateBanner.isHidden)）")
    }

    private func setStatus(_ text: String) {
        if !isExpanded {
            setCapsuleNotice(text)
            return
        }
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
app.run()
