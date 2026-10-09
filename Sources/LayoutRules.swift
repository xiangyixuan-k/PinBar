import CoreGraphics

enum LayoutRules {
    static func notchShift(_ item: CGRect, leftEdge: CGFloat, rightEdge: CGFloat) -> CGFloat {
        guard item.maxX > leftEdge, item.minX < rightEdge else { return 0 }
        return item.maxX - leftEdge + 12
    }
    static func isOnRequestedSide(_ item: CGRect, boundary: CGRect, pinned: Bool) -> Bool {
        // Compare edges, not centres: an expanded 10,000pt separator spans offscreen.
        pinned ? item.minX >= boundary.maxX - 2 : item.maxX <= boundary.minX + 2
    }
}

/// A single transient offscreen frame must not change saved visibility.
struct PositionConfirmation {
    private var candidate: CGRect?
    private var since: Double?
    mutating func observe(_ frame: CGRect?, pinned: Bool, time: Double) -> Bool {
        guard let frame, pinned ? frame.minX >= 0 : frame.maxX <= 0 else {
            candidate = nil; since = nil
            return false
        }
        if candidate != frame { candidate = frame; since = time; return false }
        return since.map { time - $0 >= 0.16 } ?? false
    }
}
