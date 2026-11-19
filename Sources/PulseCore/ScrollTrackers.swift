/// A heading as seen in one scroll probe.
public struct HeadingSample: Sendable, Hashable {
    /// Stable within a page: the accessibility element's hash.
    public var id: Int
    /// 1 for h1 ... 6 for h6, nil when the browser doesn't say.
    public var level: Int?
    /// Top edge in screen coordinates (y grows downward).
    public var top: Double

    public init(id: Int, level: Int?, top: Double) {
        self.id = id
        self.level = level
        self.top = top
    }
}

public enum ScrollDirection: Sendable, Equatable {
    case up, down
}

/// Detects a heading crossing the reading line between two scroll probes and
/// turns it into at most one landmark cue. Restraint is the point: a fast
/// fling past ten headings yields one soft pulse, not ten.
public struct LandmarkTracker: Sendable {
    /// Where on the viewport a heading "arrives": a third of the way down,
    /// roughly where reading resumes after a scroll.
    public var readingLine: Double = 1.0 / 3.0
    /// Headings deeper than this stay silent (h4–h6 are usually dense detail).
    public var deepestLevel: Int = 3
    /// No two landmark cues closer than this.
    public var minimumInterval: Double = 0.35

    private var lastTops: [Int: Double] = [:]
    private var lastCue: Double = -.infinity

    public init() {}

    public mutating func reset() {
        lastTops = [:]
    }

    /// Feeds one probe. Returns the heading that crossed, if it should cue.
    public mutating func update(
        headings: [HeadingSample],
        viewportTop: Double,
        viewportBottom: Double,
        now: Double
    ) -> HeadingSample? {
        defer { lastTops = Dictionary(headings.map { ($0.id, $0.top) }, uniquingKeysWith: { first, _ in first }) }
        guard viewportBottom > viewportTop else { return nil }
        let line = viewportTop + (viewportBottom - viewportTop) * readingLine

        var best: HeadingSample?
        for heading in headings {
            guard let previous = lastTops[heading.id],
                  abs(heading.top - previous) >= 0.5,
                  (heading.level ?? 2) <= deepestLevel
            else { continue }
            let crossed = (previous - line) * (heading.top - line) <= 0 && previous != line
            guard crossed else { continue }
            // Prefer the most important heading when several cross at once.
            if best == nil || (heading.level ?? 2) < (best?.level ?? 2) {
                best = heading
            }
        }
        guard let best, now - lastCue >= minimumInterval else { return nil }
        lastCue = now
        return best
    }
}

/// Whether a scrollable region is at its ends, from whatever the app exposes.
public struct EdgeState: Sendable, Equatable {
    public var atTop: Bool
    public var atBottom: Bool

    public init(atTop: Bool, atBottom: Bool) {
        self.atTop = atTop
        self.atBottom = atBottom
    }

    /// From a scroll bar value, 0 at the top and 1 at the bottom.
    public init(scrollBarValue value: Double) {
        self.init(atTop: value <= 0.002, atBottom: value >= 0.998)
    }

    /// From a document frame inside its viewport (screen coordinates).
    public init(documentTop: Double, documentBottom: Double, viewportTop: Double, viewportBottom: Double) {
        self.init(atTop: documentTop >= viewportTop - 1.5, atBottom: documentBottom <= viewportBottom + 1.5)
    }
}

/// Turns edge observations into the boundary cue: once on arriving at an end
/// while scrolling toward it, never repeated while held there, and once more
/// for a fresh push into an end you're already at (after a cooldown).
public struct BoundaryTracker: Sendable {
    public var cooldown: Double = 1.5

    private var heldEdge: ScrollDirection?
    private var lastCue: Double = -.infinity

    public init() {}

    public mutating func reset() {
        heldEdge = nil
    }

    public mutating func update(
        edges: EdgeState,
        direction: ScrollDirection,
        isNewGesture: Bool,
        now: Double
    ) -> Bool {
        // Content that fits entirely isn't scrollable: no ends to feel.
        guard !(edges.atTop && edges.atBottom) else {
            heldEdge = nil
            return false
        }
        // Left the edge we were holding: re-arm it.
        if heldEdge == .down && !edges.atBottom || heldEdge == .up && !edges.atTop {
            heldEdge = nil
        }
        let pushingInto: Bool = switch direction {
        case .down: edges.atBottom
        case .up: edges.atTop
        }
        guard pushingInto else { return false }
        let arriving = heldEdge != direction
        heldEdge = direction
        guard arriving || isNewGesture, now - lastCue >= cooldown else { return false }
        lastCue = now
        return true
    }
}
