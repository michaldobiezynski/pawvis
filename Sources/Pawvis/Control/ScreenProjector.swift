import AppKit
import CoreGraphics
import PawvisCore

/// Maps engine screen-normalized coordinates ([0,1] top-left origin) into
/// global display coordinates (CG space: origin at main display's top-left,
/// y down — the space CGEvent expects).
struct ScreenProjector {
    var targetRect: CGRect

    init(controlAllDisplays: Bool) {
        self.targetRect = Self.computeTarget(controlAllDisplays: controlAllDisplays)
    }

    static func computeTarget(controlAllDisplays: Bool) -> CGRect {
        guard controlAllDisplays else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        let union = displays
            .map { CGDisplayBounds($0) }
            .reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? CGDisplayBounds(CGMainDisplayID()) : union
    }

    func toGlobal(_ norm: Vec2) -> CGPoint {
        CGPoint(
            x: targetRect.minX + norm.x * targetRect.width,
            y: targetRect.minY + norm.y * targetRect.height)
    }

    /// The inverse, from an AppKit screen point (origin at the bottom-left
    /// of the primary display, y up): where a real pointer sits in engine
    /// space, clamped to the unit square.
    func toNormalized(appKitPoint point: NSPoint) -> Vec2 {
        let main = CGDisplayBounds(CGMainDisplayID())
        let cg = CGPoint(x: point.x, y: main.height - point.y)
        return Vec2((cg.x - targetRect.minX) / max(targetRect.width, 1),
                    (cg.y - targetRect.minY) / max(targetRect.height, 1)).clampedToUnit()
    }
}
