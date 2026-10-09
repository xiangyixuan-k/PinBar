import Cocoa
import os

/// Watches physical input only for the duration of a requested move. Session
/// events we generate are downstream of this tap, so they cannot overwrite the
/// user's actual pointer position. Nothing is retained after the operation.
private final class PhysicalPointerGuard {
    var pointer = CGEvent(source: nil)?.location ?? .zero
    private var initialPointer = CGPoint.zero
    var interrupted = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    func start() -> Bool {
        let initial = pointer
        let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown].reduce(0) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let state = Unmanaged<PhysicalPointerGuard>.fromOpaque(context).takeUnretainedValue()
                state.pointer = event.location
                if type == .leftMouseDown || type == .rightMouseDown ||
                    abs(event.location.x - state.initialPointer.x) + abs(event.location.y - state.initialPointer.y) > 4 {
                    state.interrupted = true
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pointer = initial
        initialPointer = initial
        return true
    }
    func finish() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    deinit { finish() }
}

extension MenuEngine {
    /// One discrete command move, without a stepped pointer trajectory.
    /// The physical-input guard keeps real user input authoritative.
    @MainActor static func routeMove(_ item: BarItem, to target: CGPoint, window targetWindow: CGWindowID) async -> Bool {
        guard AXIsProcessTrusted(), !item.fixed, NSEvent.pressedMouseButtons == 0,
              let source = CGEventSource(stateID: .combinedSessionState),
              let original = await itemFrame(item), original.minX >= 0,
              let destination = await windowFrame(targetWindow) else { return false }
        let rows = windows()
        guard let row = rows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == item.windowID }),
              let owner = row[kCGWindowOwnerPID as String] as? Int32 else { return false }
        let pointer = PhysicalPointerGuard()
        guard pointer.start() else { return false }
        defer { pointer.finish(); CGWarpMouseCursorPosition(pointer.pointer) }
        source.localEventsSuppressionInterval = 0
        let permitted: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval] {
            source.setLocalEventsFilterDuringSuppressionState(permitted, state: state)
        }
        func make(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = type == .leftMouseUp ? [] : .maskCommand
            event?.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(owner))
            if type == .leftMouseDown {
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(item.windowID))
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(item.windowID))
            }
            return event
        }
        func post(_ event: CGEvent?) {
            event?.post(tap: .cgSessionEventTap)
            event?.postToPid(owner)
        }
        let origin = CGPoint(x: original.midX, y: original.midY)
        post(make(.leftMouseDown, origin))
        try? await Task.sleep(for: .milliseconds(40))
        // Removing the source from its old slot can move the destination. Keep
        // the requested edge offset rather than using stale screen coordinates.
        let currentDestination = await windowFrame(targetWindow) ?? destination
        let end = CGPoint(x: currentDestination.minX + target.x - destination.minX, y: currentDestination.midY)
        if !pointer.interrupted { post(make(.leftMouseDragged, end)) }
        try? await Task.sleep(for: .milliseconds(40))
        post(make(.leftMouseUp, pointer.interrupted ? origin : end))
        try? await Task.sleep(for: .milliseconds(120))
        let final = await itemFrame(item)
        Logger(subsystem: "com.xiang.pinbar", category: "movement").info("Move \(item.name, privacy: .public) window \(item.windowID) from \(String(describing: original), privacy: .public) to \(String(describing: final), privacy: .public), interrupted \(pointer.interrupted)")
        guard !pointer.interrupted, let final else { return false }
        return abs(final.midX - original.midX) > 2
    }
}
