import CoreGraphics

enum HoverRules {
    static let enterDelay = 0.16
    static let leaveDelay = 0.34

    static func contains(_ point: CGPoint, anchor: CGRect, panel: CGRect?) -> Bool {
        if anchor.insetBy(dx: -3, dy: -3).contains(point) { return true }
        guard let panel else { return false }
        if panel.insetBy(dx: -6, dy: -6).contains(point) { return true }
        // A small bridge prevents a close while crossing the menu-bar gap.
        let bridge = CGRect(x: anchor.minX - 8, y: panel.maxY - 6,
                            width: anchor.width + 16,
                            height: max(0, anchor.minY - panel.maxY + 12))
        return bridge.contains(point)
    }
}
