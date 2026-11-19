import CoreGraphics

/// Remembers the last control that produced a cue, by geometry, so one visual
/// control never cues twice while the pointer stays on it, even when a web page
/// re-renders it with a fresh accessibility node mid-hover, or the hit-test
/// lands on its label, its icon, or a wrapper around it.
///
/// Identity rules follow Tactile (MIT): nesting either way, or heavy mutual
/// overlap, is the same control.
public struct ControlMemory: Sendable {
    /// Intersection over union at or above this is the same control moving.
    public static let overlapThreshold: Double = 0.6
    private static let slack: CGFloat = 2

    public private(set) var region: CGRect?

    public init() {}

    public mutating func reset() { region = nil }

    /// Starts remembering a control that just cued.
    public mutating func remember(_ frame: CGRect) { region = frame }

    /// Whether a new hit is the remembered control. A clickable, control-sized
    /// frame that belongs to it is absorbed into the region, so a badge that
    /// cued first and its enclosing tab read as one control.
    public mutating func absorbs(frame: CGRect?, isClickable: Bool, at point: CGPoint) -> Bool {
        guard let region else { return false }
        let grownRegion = region.insetBy(dx: -Self.slack, dy: -Self.slack)
        let pointInside = grownRegion.contains(point)
        guard let frame else { return pointInside } // Frameless re-render inside it.

        let grownFrame = frame.insetBy(dx: -Self.slack, dy: -Self.slack)
        let overlaps = Self.overlapRatio(frame, region) >= Self.overlapThreshold
        let same: Bool
        if pointInside {
            same = grownRegion.contains(frame) || grownFrame.contains(region) || overlaps
        } else {
            // Outside the cued frame only an enclosing control (not an inert
            // window-sized container) or heavy overlap still counts.
            same = isClickable
                && ((ElementClassifier.isControlSized(frame) && grownFrame.contains(region)) || overlaps)
        }
        if same, isClickable, ElementClassifier.isControlSized(frame) {
            self.region = region.union(frame)
        }
        return same
    }

    /// Whether the pointer is still inside the remembered control.
    public func contains(_ point: CGPoint) -> Bool {
        region?.insetBy(dx: -Self.slack, dy: -Self.slack).contains(point) ?? false
    }

    public static func overlapRatio(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let shared = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height + b.width * b.height) - shared
        return union > 0 ? shared / union : 0
    }
}
