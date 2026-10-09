import Cocoa
import ApplicationServices
import os

struct BarItem: Identifiable {
    let id: String
    let name: String
    let detail: String
    let appPID: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let element: AXUIElement
    let icon: NSImage
    let fixed: Bool
}

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
    return result
}
func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axValue(element, kAXPositionAttribute), let s = axValue(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

enum MenuEngine {
    static func windowFrame(_ id: CGWindowID) async -> CGRect? {
        await Task.detached(priority: .userInitiated) {
            guard id != 0,
                  let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                  let row = rows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == id }),
                  let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }.value
    }
    static func itemFrame(_ item: BarItem) async -> CGRect? {
        if let frame = await windowFrame(item.windowID) { return frame }
        return await currentFrame(item.element)
    }
    static func press(_ element: AXUIElement) async -> AXError {
        await Task.detached(priority: .userInitiated) {
            AXUIElementSetMessagingTimeout(element, 0.2)
            return AXUIElementPerformAction(element, kAXPressAction as CFString)
        }.value
    }
    static func currentFrame(_ element: AXUIElement) async -> CGRect? {
        await Task.detached(priority: .userInitiated) {
            AXUIElementSetMessagingTimeout(element, 0.2)
            return axFrame(element)
        }.value
    }
    static func windows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
            guard let bounds = $0[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return ($0[kCGWindowLayer as String] as? Int) == 25 && frame.height >= 20 && frame.height <= 50
        }
    }
    static func scan() -> [BarItem] {
        var items: [BarItem] = []
        for app in NSWorkspace.shared.runningApplications {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.08)
            guard let rawBar = axValue(root, kAXExtrasMenuBarAttribute), CFGetTypeID(rawBar) == AXUIElementGetTypeID(),
                  let children = axValue(rawBar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            var ordinal = 0
            for element in children {
                AXUIElementSetMessagingTimeout(element, 0.15)
                guard var frame = axFrame(element), frame.height > 0 else { continue }
                let title = axValue(element, kAXTitleAttribute) as? String ?? ""
                let desc = axValue(element, kAXDescriptionAttribute) as? String ?? ""
                let identifier = axValue(element, kAXIdentifierAttribute) as? String ?? ""
                // Read windows beside each AX frame. A single snapshot taken
                // before a multi-second scan can identify a neighbouring icon
                // after the status bar reflows during application startup.
                let liveWindows = windows()
                if let latest = axFrame(element) { frame = latest }
                let nearest = liveWindows.min { a, b in
                    func distance(_ w: [String: Any]) -> CGFloat {
                        guard let bounds = w[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return .greatestFiniteMagnitude }
                        return abs(r.midX - frame.midX) + abs(r.midY - frame.midY)
                    }
                    return distance(a) < distance(b)
                }
                let match: [String: Any]?
                if let nearest, let bounds = nearest[kCGWindowBounds as String] as? [String: Any],
                   let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                   abs(rect.midX - frame.midX) < 3, abs(rect.midY - frame.midY) < 3,
                   abs(rect.width - frame.width) < 4 {
                    match = nearest
                } else { match = nil }
                let windowName = match?[kCGWindowName as String] as? String ?? ""
                let system = app.bundleIdentifier == "com.apple.controlcenter"
                let fixed = system && ["clock", "controlcenter", "siri", "audiovideo", "screenrecording"].contains { identifier.lowercased().contains($0) }
                let name: String
                if system {
                    let systemNames = ["clock": "时钟", "controlcenter": "控制中心", "audiovideo": "音频和视频控制", "display": "显示器", "wifi": "Wi-Fi", "sound": "声音", "bluetooth": "蓝牙", "battery": "电池", "siri": "Siri"]
                    let component = identifier.components(separatedBy: ".").last ?? ""
                    name = systemNames[component] ?? (desc.components(separatedBy: "，").first ?? windowName)
                }
                else if app.bundleIdentifier == "com.apple.TextInputMenuAgent" { name = "输入法" }
                else { name = app.localizedName ?? "菜单栏程序" }
                let suffix = children.count > 1 && !system ? " · \(metricName(windowName, ordinal))" : ""
                let key = (app.bundleIdentifier ?? String(app.processIdentifier)) + "|" + (identifier.isEmpty ? String(ordinal) : identifier)
                let icon: NSImage
                if app.bundleIdentifier?.hasPrefix("com.apple.") == true {
                    icon = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "Apple 系统项目")!
                } else {
                    icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
                }
                let wid = match?[kCGWindowNumber as String] as? UInt32 ?? 0
                items.append(BarItem(id: key, name: name + suffix, detail: system ? "系统项目" : (desc.isEmpty ? (title.isEmpty ? "菜单栏程序" : title) : desc), appPID: app.processIdentifier, windowID: wid, frame: frame, element: element, icon: icon, fixed: fixed))
                ordinal += 1
            }
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }
    static func metricName(_ title: String, _ index: Int) -> String {
        if title.hasPrefix("CPU") { return "CPU" }
        if title.hasPrefix("GPU") { return "GPU" }
        if title.hasPrefix("Network") { return "网速" }
        if title.hasPrefix("Sensors") { return "温度" }
        return "\(index + 1)"
    }
    static func hasOpenMenu(for item: BarItem) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let host = windows().first { $0[kCGWindowNumber as String] as? UInt32 == item.windowID }?[kCGWindowOwnerPID as String] as? Int32
        return rows.contains { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  pid == item.appPID || pid == host,
                  let layer = row[kCGWindowLayer as String] as? Int, layer >= 3,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.height > 50 && rect.width > 60
        }
    }
}
