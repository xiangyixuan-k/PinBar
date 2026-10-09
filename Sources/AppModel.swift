import Cocoa
import SwiftUI
import ServiceManagement
import os

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [BarItem] = []
    @Published var busy = false
    @Published var processingItemID: String?
    @Published var queuedPinIDs = Set<String>()
    @Published var pendingOpenItemID: String?
    @Published var loading = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var accessRequested = false
    @Published var expanded = true
    @Published var message = "点亮图钉常驻，取消图钉收起。"
    @Published var hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenItems") ?? [])
    @Published var failedHidden = Set<String>()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hoverToOpen = UserDefaults.standard.object(forKey: "hoverToOpen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hoverToOpen, forKey: "hoverToOpen") }
    }
    var divider: NSStatusItem!
    var controller: NSStatusItem!
    var closePanel: (() -> Void)?
    var showPanel: (() -> Void)?
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var restoredSavedLayout = false
    private var menuSessionTask: Task<Void, Never>?
    private var boundaryElement: AXUIElement?
    private var controllerElement: AXUIElement?
    private var boundaryWindowID: CGWindowID?
    private var controllerWindowID: CGWindowID?
    private var scanning = false
    private var lastScan = Date.distantPast
    private var queuedPins: [BarItem] = []
    private var queuedPinTargets: [String: Bool] = [:]
    private var pendingOpenItem: BarItem?

    func start() {
        controller = NSStatusBar.system.statusItem(withLength: 26)
        controller.autosaveName = "PinBar.Main"
        controller.button?.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "PinBar 菜单")
        controller.button?.setAccessibilityLabel("PinBar 菜单")
        controller.button?.toolTip = "PinBar · 管理菜单栏图标"
        let defaults = UserDefaults.standard
        if let saved = defaults.object(forKey: "boundaryPreferredPosition") ?? defaults.object(forKey: "NSStatusItem Preferred Position PinBar.Boundary") {
            defaults.set(saved, forKey: "NSStatusItem Preferred Position PinBar.Boundary")
            defaults.synchronize()
            createBoundary()
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy else { return }
                let next = AXIsProcessTrusted()
                if next != self.trusted {
                    self.trusted = next
                    if next { self.message = "已连接菜单栏，正在读取程序。" }
                    else { self.message = "连接已断开，请检查系统设置中的 PinBar 开关。" }
                    self.refresh()
                }
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    self?.refresh()
                }
            }
            workspaceObservers.append(observer)
        }
    }
    func checkAccess() {
        trusted = AXIsProcessTrusted()
        message = trusted ? "已连接菜单栏，正在读取程序。" : "尚未连接。请在系统设置中打开 PinBar 的辅助功能开关。"
        refresh()
    }
    func refresh() {
        guard !scanning, !busy else { return }
        trusted = AXIsProcessTrusted()
        guard trusted else {
            items = []
            message = "等待连接：请在系统设置中允许 PinBar 使用辅助功能。"
            return
        }
        scanning = true
        loading = items.isEmpty
        Task {
            defer { scanning = false; loading = false }
            if items.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            let scanned = await Task.detached(priority: .userInitiated) { MenuEngine.scan() }.value
            guard AXIsProcessTrusted() else {
                trusted = false; items = []; loading = false; return
            }
            // A background refresh must not replace AX references midway
            // through an operation the user started from the cached list.
            guard !busy else { return }
            lastScan = Date()
            if divider == nil {
                // Earlier releases explicitly removed the status item on quit,
                // which deletes AppKit's autosaved position. Recreate only our
                // separator, keeping all other applications' native ordering.
                let pinnedLeft = scanned.filter {
                    $0.appPID != ProcessInfo.processInfo.processIdentifier && !hidden.contains($0.id) && $0.frame.minX >= 0
                }.map { $0.frame.minX }.min()
                let mainPosition = UserDefaults.standard.double(forKey: "NSStatusItem Preferred Position PinBar.Main")
                if let pinnedLeft, let main = controllerFrame() {
                    let position = max(0, mainPosition + main.maxX - pinnedLeft + 1)
                    UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position PinBar.Boundary")
                    UserDefaults.standard.set(position, forKey: "boundaryPreferredPosition")
                    UserDefaults.standard.synchronize()
                }
                createBoundary()
                // Wait for the single group collapse before judging visibility.
                try? await Task.sleep(for: .milliseconds(180))
            }
            let own = scanned.filter { $0.appPID == ProcessInfo.processInfo.processIdentifier }
            boundaryElement = own.first { $0.detail.contains("收纳边界") || $0.id == "com.xiang.pinbar|1" }?.element
            controllerElement = own.first { $0.detail.contains("PinBar 菜单") || $0.id == "com.xiang.pinbar|0" }?.element
            let statusWindows = MenuEngine.windows()
            boundaryWindowID = statusWindows.first { $0[kCGWindowName as String] as? String == "PinBar.Boundary" }?[kCGWindowNumber as String] as? UInt32
                ?? own.first { $0.id == "com.xiang.pinbar|1" && $0.windowID != 0 }?.windowID
            controllerWindowID = statusWindows.first { $0[kCGWindowName as String] as? String == "PinBar.Main" }?[kCGWindowNumber as String] as? UInt32
                ?? own.first { $0.id == "com.xiang.pinbar|0" && $0.windowID != 0 }?.windowID
            items = scanned.filter { $0.appPID != ProcessInfo.processInfo.processIdentifier }
            if !expanded {
                var remaining = Set<String>()
                for item in items where hidden.contains(item.id) {
                    if let frame = await MenuEngine.itemFrame(item), frame.maxX > 0 { remaining.insert(item.id) }
                }
                failedHidden = remaining
            }
            loading = false
            if items.isEmpty {
                message = "尚未读取到项目。请确认授权的是当前这份 PinBar，然后重新检查。"
                return
            }
            if !restoredSavedLayout {
                restoredSavedLayout = true
                message = failedHidden.isEmpty ? "移到拼图上查看，移开轻轻收回。" : "\(failedHidden.count) 个项目仍在菜单栏，列表已标明。"
                drainPendingOperations()
            }
        }
    }
    func refreshIfNeeded() {
        if items.isEmpty || Date().timeIntervalSince(lastScan) >= 30 { refresh() }
    }
    private func createBoundary(expanded: Bool = false) {
        divider = NSStatusBar.system.statusItem(withLength: 10)
        divider.autosaveName = "PinBar.Boundary"
        divider.button?.setAccessibilityLabel("PinBar 收纳边界")
        divider.button?.toolTip = "PinBar 收纳边界"
        setExpanded(expanded)
    }
    private func statusFrame(_ item: NSStatusItem) -> CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard rect.width > 0 else { return nil }
        return CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }
    func controllerScreenFrame() -> CGRect? {
        guard let button = controller?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    func boundaryFrame() -> CGRect? { divider.map { statusFrame($0) } ?? nil }
    func controllerFrame() -> CGRect? { statusFrame(controller) }
    private func actualBoundaryFrame() async -> CGRect? {
        if let boundaryWindowID { return await MenuEngine.windowFrame(boundaryWindowID) }
        if let boundaryElement { return await MenuEngine.currentFrame(boundaryElement) }
        return boundaryFrame()
    }
    private func actualControllerFrame() async -> CGRect? {
        if let controllerWindowID { return await MenuEngine.windowFrame(controllerWindowID) }
        if let controllerElement { return await MenuEngine.currentFrame(controllerElement) }
        return controllerFrame()
    }
    func setExpanded(_ value: Bool, anticipatingHidden: Bool = false) {
        expanded = value
        guard let divider else { return }
        let reveal = value || (hidden.isEmpty && !anticipatingHidden)
        divider.length = reveal ? 10 : 10000
        divider.button?.title = reveal ? "│" : ""
    }
    func toggleExpanded() { guard !busy else { return }; setExpanded(!expanded) }
    func isPinned(_ item: BarItem) -> Bool { !hidden.contains(item.id) || failedHidden.contains(item.id) }
    private func save() { UserDefaults.standard.set(Array(hidden), forKey: "hiddenItems") }

    func togglePin(_ item: BarItem, requestedPin: Bool? = nil) {
        guard trusted, !loading, !item.fixed else { return }
        let shouldPin = requestedPin ?? !isPinned(item)
        if busy {
            guard processingItemID != item.id else { return }
            if queuedPinIDs.contains(item.id) {
                queuedPinIDs.remove(item.id)
                queuedPins.removeAll { $0.id == item.id }
                queuedPinTargets.removeValue(forKey: item.id)
            } else {
                queuedPinIDs.insert(item.id)
                queuedPins.append(item)
                queuedPinTargets[item.id] = shouldPin
            }
            return
        }
        menuSessionTask?.cancel()
        busy = true
        processingItemID = item.id
        message = shouldPin ? "正在显示 \(item.name)…" : "正在收起 \(item.name)…"
        Task {
            let started = ContinuousClock.now
            let moved = await position(item, pin: shouldPin)
            setExpanded(false, anticipatingHidden: !shouldPin)
            let verified: Bool
            if shouldPin { verified = moved ? await verifyStablePosition(item, pinned: true) : false }
            else { verified = await verifyHidden(item) }
            if verified {
                if shouldPin { hidden.remove(item.id) } else { hidden.insert(item.id) }
                failedHidden.remove(item.id)
                save()
                message = shouldPin ? "\(item.name) 已显示在菜单栏。" : "\(item.name) 已收起，点击名称即可打开。"
            } else if !shouldPin {
                if hidden.contains(item.id) { failedHidden.insert(item.id) }
                message = "\(item.name) 未能收起，设置未改变。可临时展开后按住 ⌘ 将它移到分隔线左侧。"
            } else {
                message = "\(item.name) 未能常驻，设置未改变。可临时展开后按住 ⌘ 将它移到分隔线右侧。"
            }
            setExpanded(false)
            captureBoundaryPosition()
            processingItemID = nil
            busy = false
            Logger(subsystem: "com.xiang.pinbar", category: "movement").info("Pin \(item.name, privacy: .public) desired \(shouldPin), verified \(verified), completed in \(String(describing: started.duration(to: .now)), privacy: .public)")
            drainPendingOperations()
        }
    }
    private func drainPendingOperations() {
        guard !busy else { return }
        if !queuedPins.isEmpty {
            let next = queuedPins.removeFirst()
            queuedPinIDs.remove(next.id)
            let desired = queuedPinTargets.removeValue(forKey: next.id)
            togglePin(next, requestedPin: desired)
        } else if let next = pendingOpenItem {
            pendingOpenItem = nil
            pendingOpenItemID = nil
            openItem(next)
        }
    }
    private func verifyHidden(_ item: BarItem) async -> Bool {
        await verifyStablePosition(item, pinned: false)
    }
    private func verifyStablePosition(_ item: BarItem, pinned: Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(950))
        var confirmation = PositionConfirmation()
        repeat {
            if confirmation.observe(await MenuEngine.itemFrame(item), pinned: pinned, time: ProcessInfo.processInfo.systemUptime) { return true }
            try? await Task.sleep(for: .milliseconds(35))
        } while ContinuousClock.now < deadline
        return false
    }
    /// Alters only geometry. The caller commits preferences after verification.
    private func position(_ item: BarItem, pin: Bool) async -> Bool {
        // Already-hidden items need no expansion, especially during startup.
        if !pin, !expanded, let frame = await MenuEngine.itemFrame(item), frame.maxX <= 0 { return true }
        setExpanded(true)
        // Status items are hosted remotely. Wait for real layout acknowledgement,
        // rather than treating a still-hidden frame as an offscreen failure.
        var settled: (CGRect, CGRect)?
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(900))
        repeat {
            if let boundary = await actualBoundaryFrame(), boundary.width < 100, boundary.minX >= 0,
               let frame = await MenuEngine.itemFrame(item) {
                settled = (boundary, frame)
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        guard let (boundary, frame) = settled else {
            message = "\(item.name) 暂时超出屏幕。先收起几个可见项目，再试一次。"
            return false
        }
        if LayoutRules.isOnRequestedSide(frame, boundary: boundary, pinned: pin) { return true }
        let currentController = await actualControllerFrame()
        let target = CGPoint(x: pin ? (currentController?.maxX ?? boundary.maxX) : boundary.minX, y: boundary.midY)
        let destinationWindow = pin ? controllerWindowID : boundaryWindowID
        // An explicit pin click requests a single system relocation.
        // Startup, hover, and opening an item never use this route.
        if let destinationWindow { _ = await MenuEngine.routeMove(item, to: CGPoint(x: target.x + (pin ? 6 : -6), y: target.y), window: destinationWindow) }
        if await verifySide(item, pin: pin) { return true }
        message = "\(item.name) 暂时无法移动，图钉设置未改变。可展开后按住 ⌘ 拖动原图标，再刷新。"
        return false
    }
    private func verifySide(_ item: BarItem, pin: Bool) async -> Bool {
        // Remote status windows can reflow after event delivery returns.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(650))
        repeat {
            if let newBoundary = await actualBoundaryFrame(), newBoundary.width < 100, let final = await MenuEngine.itemFrame(item), LayoutRules.isOnRequestedSide(final, boundary: newBoundary, pinned: pin) { return true }
            try? await Task.sleep(for: .milliseconds(35))
        } while ContinuousClock.now < deadline
        return false
    }
    func openItem(_ item: BarItem) {
        guard trusted, !loading else { return }
        if busy {
            pendingOpenItem = item
            pendingOpenItemID = item.id
            return
        }
        busy = true
        menuSessionTask?.cancel()
        closePanel?()
        Task {
            // Reveal the existing group as a whole; opening a hidden program
            // must never move it out of its saved position and back again.
            if !isPinned(item) {
                setExpanded(true)
                try? await Task.sleep(for: .milliseconds(180))
            }
            let result = await MenuEngine.press(item.element)
            busy = false
            if result != .success {
                setExpanded(true)
                message = "已展开菜单栏，请点击 \(item.name) 的原图标。"
                showPanel?()
            } else if expanded {
                message = "菜单关闭后，收纳区会自动收回。"
                menuSessionTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    while !Task.isCancelled {
                        guard !busy else { return }
                        let pointer = NSEvent.mouseLocation
                        let inMenuBar = NSScreen.screens.contains { $0.frame.contains(pointer) && pointer.y >= $0.visibleFrame.maxY }
                        if !inMenuBar && !MenuEngine.hasOpenMenu(for: item) && NSEvent.pressedMouseButtons == 0 {
                            setExpanded(false)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            drainPendingOperations()
        }
    }
    func requestAccess() {
        accessRequested = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { message = "请在系统设置的登录项中允许 PinBar。" }
        } catch { message = "开机启动未设置成功，请稍后重试。" }
    }
    private func captureBoundaryPosition() {
        let rows = MenuEngine.windows()
        func frame(_ name: String) -> CGRect? {
            guard let row = rows.first(where: { $0[kCGWindowName as String] as? String == name }),
                  let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        guard let boundary = frame("PinBar.Boundary"), let main = frame("PinBar.Main") else { return }
        let mainPosition = UserDefaults.standard.double(forKey: "NSStatusItem Preferred Position PinBar.Main")
        UserDefaults.standard.set(max(0, mainPosition + main.maxX - boundary.maxX), forKey: "boundaryPreferredPosition")
    }
    func quit() {
        captureBoundaryPosition()
        menuSessionTask?.cancel(); timer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let divider {
            let key = "NSStatusItem Preferred Position PinBar.Boundary"
            let saved = UserDefaults.standard.object(forKey: key)
            divider.length = 10
            NSStatusBar.system.removeStatusItem(divider)
            // AppKit deletes this preference when explicitly removing an item.
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
        }
        NSApp.terminate(nil)
    }
}
