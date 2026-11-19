import CoreGraphics

/// What an accessibility element under the pointer (or in focus) is, as far as
/// Pulse's cues care.
public enum ElementKind: String, Sendable, CaseIterable {
    case link, button, toggle, tab, menuItem
    /// A custom control that only advertises a press action (common on the web).
    case otherClickable
    case field
    case heading

    /// Whether hover or focus landing here deserves the actionable tick.
    public var isActionable: Bool {
        switch self {
        case .link, .button, .toggle, .tab, .menuItem, .otherClickable: true
        case .field, .heading: false
        }
    }

    /// Kinds whose label names an action, so a destructive word means danger.
    /// Links and tabs are navigation: their text is content.
    var labelNamesAnAction: Bool {
        switch self {
        case .button, .menuItem, .toggle, .otherClickable: true
        case .link, .tab, .field, .heading: false
        }
    }
}

/// Maps macOS accessibility roles to element kinds. Pure logic, so it can be
/// tested without a live accessibility tree.
///
/// The role table and the size and fragment heuristics follow Tactile
/// (MIT, github.com/Mason363/Tactile), which proved them across native,
/// web, and Electron apps.
public enum ElementClassifier {
    /// Classifies from role and subrole alone. Returns nil when the role says
    /// nothing; callers may then check actions with `isPressable(actions:)`.
    public static func kind(role: String, subrole: String?) -> ElementKind? {
        // Subroles are more specific, so they win: native tabs are
        // AXRadioButton + AXTabButton.
        switch subrole {
        case "AXTabButton": return .tab
        case "AXToggle", "AXSwitch": return .toggle
        case "AXSearchField", "AXSecureTextField": return .field
        // Sidebar rows (Finder, Mail, Settings) expose no press action.
        case "AXOutlineRow": return .button
        default: break
        }
        switch role {
        case "AXButton": return .button
        case "AXLink": return .link
        case "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle": return .toggle
        case "AXTab": return .tab
        case "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXComboBox": return .menuItem
        case "AXTextField", "AXTextArea": return .field
        case "AXHeading": return .heading
        default: return nil
        }
    }

    /// Custom controls often use generic roles but advertise a press action.
    /// Finder items advertise AXOpen instead. AXShowMenu is excluded: it sits
    /// on many inert containers.
    public static func isPressable(actions: [String]) -> Bool {
        actions.contains("AXPress") || actions.contains("AXOpen")
    }

    /// Roles that are never controls themselves but often contain one, so the
    /// hit-tester walks up from them instead of asking for actions.
    public static let decorativeRoles: Set<String> = ["AXStaticText", "AXImage", "AXUnknown"]

    /// Roles where an upward search for the owning control stops.
    public static let structuralRoles: Set<String> = [
        "AXWindow", "AXSheet", "AXDrawer", "AXApplication", "AXMenuBar", "AXWebArea", "AXScrollArea",
    ]

    /// Containers whose selection changing means "your place changed".
    public static let navigationContainerRoles: Set<String> = [
        "AXOutline", "AXList", "AXTable", "AXTabGroup", "AXRadioGroup", "AXBrowser",
    ]

    /// Plausible bounds for one control. Electron and web apps mark
    /// window-sized groups as pressable; those are containers, not targets.
    public static func isControlSized(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0
            && frame.width <= 900 && frame.height <= 350
            && frame.width * frame.height <= 160_000
    }

    /// A pressable element this large is probably a wrapper holding the real
    /// control, so the resolver looks inside it first.
    public static func isLikelyWrapper(_ frame: CGRect) -> Bool {
        frame.width > 420 || frame.height > 120
    }
}

/// The importance story Pulse tells as the pointer moves. This is based only
/// on an element's accessibility role, not its text or appearance:
/// lightweight navigation is a small tick; controls that change state are a
/// medium pulse; `CautionDetector` upgrades destructive and invalid controls
/// to the strong caution cue.
public enum ControlCueClassifier {
    public static func cue(for kind: ElementKind) -> Cue? {
        switch kind {
        case .link, .otherClickable:
            .actionable
        case .button, .toggle, .tab, .menuItem:
            .action
        case .field, .heading:
            nil
        }
    }
}

/// Decides when a control deserves the caution cue instead of the ordinary
/// tick. Labels are only inspected transiently and are never stored.
public enum CautionDetector {
    static let destructiveWords: Set<String> = [
        "delete", "remove", "trash", "erase", "discard", "uninstall",
        "clear", "reset", "quit", "close", "empty", "eject", "disconnect",
        "terminate", "destroy", "wipe", "forget", "revoke", "unsubscribe",
    ]

    public static func isDestructive(kind: ElementKind, subrole: String?, label: String?) -> Bool {
        if subrole == "AXCloseButton" { return true }
        guard kind.labelNamesAnAction, let label, !label.isEmpty,
              label.count <= 40 // Long text is content leaking out of a wrapper.
        else { return false }
        return label.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { destructiveWords.contains(String($0)) }
    }

    /// `AXInvalid` is a string in WebKit and Chromium ("true", "false",
    /// "spelling", "grammar"); only a plain invalid value is an error.
    public static func isInvalid(_ value: String?) -> Bool {
        value?.lowercased() == "true"
    }
}
