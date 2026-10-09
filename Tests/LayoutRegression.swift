import CoreGraphics

@main
struct LayoutRegression {
    static func main() {
        let separator = CGRect(x: 800, y: 8, width: 10, height: 24)
        precondition(LayoutRules.isOnRequestedSide(CGRect(x: 810, y: 8, width: 24, height: 24), boundary: separator, pinned: true))
        precondition(LayoutRules.isOnRequestedSide(CGRect(x: 774, y: 8, width: 24, height: 24), boundary: separator, pinned: false))
        // A wide status item can overlap the separator while its centre appears hidden.
        // It must not be committed to hidden preferences until its full frame crosses.
        let overlapping = CGRect(x: 700, y: 8, width: 180, height: 24)
        precondition(!LayoutRules.isOnRequestedSide(overlapping, boundary: separator, pinned: false))
        let expanded = CGRect(x: -9190, y: 8, width: 10000, height: 24)
        precondition(!LayoutRules.isOnRequestedSide(CGRect(x: 500, y: 8, width: 24, height: 24), boundary: expanded, pinned: true))
        precondition(LayoutRules.isOnRequestedSide(CGRect(x: 810, y: 8, width: 24, height: 24), boundary: expanded, pinned: true))
        precondition(LayoutRules.notchShift(CGRect(x: 908, y: 8, width: 18, height: 24), leftEdge: 790, rightEdge: 1010) == 148)
        precondition(LayoutRules.notchShift(CGRect(x: 1010, y: 8, width: 18, height: 24), leftEdge: 790, rightEdge: 1010) == 0)
        precondition(LayoutRules.notchShift(CGRect(x: 770, y: 8, width: 20, height: 24), leftEdge: 790, rightEdge: 1010) == 0)
        let anchor = CGRect(x: 1200, y: 1134, width: 26, height: 24)
        let panel = CGRect(x: 1023, y: 543, width: 380, height: 580)
        precondition(HoverRules.contains(CGPoint(x: 1213, y: 1146), anchor: anchor, panel: nil))
        precondition(!HoverRules.contains(CGPoint(x: 1213, y: 1000), anchor: anchor, panel: nil))
        precondition(HoverRules.contains(CGPoint(x: 1213, y: 1129), anchor: anchor, panel: panel))
        precondition(HoverRules.contains(CGPoint(x: 1030, y: 600), anchor: anchor, panel: panel))
        precondition(!HoverRules.contains(CGPoint(x: 900, y: 1129), anchor: anchor, panel: panel))
        // Secondary displays can have negative coordinates.
        precondition(HoverRules.contains(CGPoint(x: -587, y: 1129), anchor: anchor.offsetBy(dx: -1800, dy: 0), panel: panel.offsetBy(dx: -1800, dy: 0)))
        var hiddenConfirmation = PositionConfirmation()
        let hidden = CGRect(x: -200, y: 0, width: 22, height: 39)
        let visible = CGRect(x: 1282, y: 0, width: 22, height: 39)
        precondition(!hiddenConfirmation.observe(hidden, pinned: false, time: 0))
        precondition(!hiddenConfirmation.observe(visible, pinned: false, time: 0.05))
        precondition(!hiddenConfirmation.observe(hidden, pinned: false, time: 0.1))
        precondition(!hiddenConfirmation.observe(hidden, pinned: false, time: 0.24))
        precondition(hiddenConfirmation.observe(hidden, pinned: false, time: 0.27))
        precondition(!hiddenConfirmation.observe(hidden.offsetBy(dx: -50, dy: 0), pinned: false, time: 0.28))
        var pinnedConfirmation = PositionConfirmation()
        precondition(!pinnedConfirmation.observe(visible, pinned: true, time: 0))
        precondition(pinnedConfirmation.observe(visible, pinned: true, time: 0.18))
        print("Layout, hover and visibility regression: 22 checks passed.")
    }
}
