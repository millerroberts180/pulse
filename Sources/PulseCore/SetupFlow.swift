/// The setup window's steps. The tour comes first because it needs no
/// permission. The permission comes next, just before typing, the first
/// thing that needs it.
public enum SetupStep: Int, CaseIterable, Sendable {
    case tour, permission, typing, done

    /// The steps one run shows. Opened again later, setup is the tutorial:
    /// the same teaching steps, without the permission.
    public static func steps(tutorialOnly: Bool) -> [SetupStep] {
        tutorialOnly ? [.tour, .typing, .done] : allCases
    }
}

/// The tour's checklist. A cue ticks off once it has played and been felt.
/// Motion with no finger on the trackpad (momentum after a flick, a mouse
/// wheel) is heard but not felt, so it only names the cue.
public struct TourChecklist: Sendable, Equatable {
    public private(set) var felt: Set<Cue> = []
    /// The latest cue, felt or not: the tour says what it means.
    public private(set) var latest: Cue?

    public init() {}

    public mutating func played(_ cue: Cue, felt: Bool) {
        latest = cue
        if felt { self.felt.insert(cue) }
    }
}

/// How the tour decides the cue for one of its own elements, by the live
/// page detector's rules (`PageDetector`): the same role table, the same
/// caution check, the same timing. The detectors never read Pulse's own
/// windows, so the tour applies the rules to its page itself.
public enum TourCue {
    /// Content that scrolled under a still pointer stays silent this long.
    public static let scrollSettle: Double = 0.3
    /// Focus this soon after a click came from the click, already felt on hover.
    public static let focusAfterClick: Double = 0.4
    /// Selection changes closer together than this are one move.
    public static let navigationInterval: Double = 0.12

    /// The pointer moved onto an element. Fields and headings have no hover cue.
    public static func hover(role: String, subrole: String?, label: String?, sinceScroll: Double) -> Cue? {
        guard sinceScroll >= scrollSettle, let kind = ElementClassifier.kind(role: role, subrole: subrole) else { return nil }
        if CautionDetector.isDestructive(kind: kind, subrole: subrole, label: label) { return .caution }
        return ControlCueClassifier.cue(for: kind)
    }

    /// Keyboard focus landed on an element. `invalid` is its `AXInvalid`
    /// value: a field with an error cues even when a click focused it.
    public static func focus(role: String, subrole: String?, label: String?, invalid: String?, sinceClick: Double) -> Cue? {
        guard let kind = ElementClassifier.kind(role: role, subrole: subrole) else { return nil }
        if kind == .field { return CautionDetector.isInvalid(invalid) ? .caution : nil }
        guard kind.isActionable, sinceClick >= focusAfterClick else { return nil }
        if CautionDetector.isDestructive(kind: kind, subrole: subrole, label: label) { return .caution }
        return ControlCueClassifier.cue(for: kind)
    }
}
