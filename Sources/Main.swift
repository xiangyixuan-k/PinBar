import Cocoa
import SwiftUI

final class PinBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var panel: NSPanel!
    var localMonitor: Any?
    private var hoverTimer: Timer?
    private var enteredAt: TimeInterval?
    private var leftAt: TimeInterval?
    private var hoverPresentation = false
    private var suppressHoverUntilExit = false
    private var panelAnimationGeneration = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
        model.controller.button?.target = self
        model.controller.button?.action = #selector(togglePanel)
        panel = PinBarPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 580), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "PinBar 菜单栏管理"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let host = NSHostingView(rootView: PanelView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true
        panel.contentView = host
        model.closePanel = { [weak self] in self?.hidePanel() }
        model.showPanel = { [weak self] in self?.showPanel(refresh: false) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                MainActor.assumeIsolated { self?.hidePanel() }
                return nil
            }
            if event.type == .leftMouseDown, event.window === self?.panel {
                MainActor.assumeIsolated {
                    self?.hoverPresentation = false
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            return event
        }
        hoverTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        RunLoop.main.add(hoverTimer!, forMode: .common)
        // Launch stays in the menu bar; hover or an explicit click opens it.
    }
    @objc func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }
    func showPanel(refresh: Bool = true, hover: Bool = false) {
        if refresh { model.refreshIfNeeded() }
        let anchor = model.controllerScreenFrame()
        let screen = NSScreen.screens.first { screen in
            anchor.map { screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
        } ?? NSScreen.main ?? NSScreen.screens.first!
        let available = screen.visibleFrame
        let desiredX = anchor.map { $0.midX - 190 } ?? available.maxX - 400
        let x = min(max(available.minX + 12, desiredX), available.maxX - 392)
        let origin = NSPoint(x: x, y: available.maxY - 588)
        let animate = (!panel.isVisible || panel.alphaValue < 0.99) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hoverPresentation = hover
        enteredAt = nil
        leftAt = nil
        panelAnimationGeneration += 1
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + (animate ? 6 : 0)))
        panel.alphaValue = animate ? 0 : 1
        if hover {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(origin)
            }
        }
    }
    func hidePanel() {
        hoverPresentation = false
        enteredAt = nil
        leftAt = nil
        suppressHoverUntilExit = true
        panelAnimationGeneration += 1
        let generation = panelAnimationGeneration
        guard panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil); panel.alphaValue = 1; return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panelAnimationGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }
    private func updateHover() {
        guard let panel, let anchor = model.controllerScreenFrame() else { return }
        let pointer = NSEvent.mouseLocation
        let onAnchor = anchor.insetBy(dx: -3, dy: -3).contains(pointer)
        if !onAnchor { suppressHoverUntilExit = false }
        guard model.hoverToOpen, NSEvent.pressedMouseButtons == 0 else {
            enteredAt = nil
            leftAt = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if !panel.isVisible {
            leftAt = nil
            guard onAnchor, !suppressHoverUntilExit else { enteredAt = nil; return }
            if let enteredAt {
                if now - enteredAt >= HoverRules.enterDelay {
                    showPanel(refresh: false, hover: true)
                }
            } else { enteredAt = now }
        } else if hoverPresentation {
            let inside = HoverRules.contains(pointer, anchor: anchor, panel: panel.frame)
            guard !inside, !model.busy else { leftAt = nil; return }
            if let leftAt {
                if now - leftAt >= HoverRules.leaveDelay { hidePanel() }
            } else { leftAt = now }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        hoverTimer?.invalidate()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        model.divider?.length = 10
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
}

@main
struct PinBarMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            let items = MenuEngine.scan()
            let rows = items.map { ["id": $0.id, "name": $0.name, "fixed": $0.fixed, "x": $0.frame.minX, "pid": $0.appPID] as [String: Any] }
            let result: [String: Any] = ["trusted": AXIsProcessTrusted(), "items": rows]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let output = String(data: data, encoding: .utf8) { print(output) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
