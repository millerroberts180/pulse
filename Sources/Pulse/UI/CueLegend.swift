import PulseCore

/// What each cue means, in the words the setup's tour and Settings › Cues use.
struct CueInfo: Identifiable {
    var cue: Cue
    var name: String
    var meaning: String
    var feel: String
    var symbol: String
    var id: Cue { cue }

    /// Every cue, in the order the tour's checklist shows them.
    static let all: [CueInfo] = [
        CueInfo(cue: .actionable, name: "Link", meaning: "The pointer or keyboard focus reached a link.",
                feel: "One light tick", symbol: "link"),
        CueInfo(cue: .action, name: "Control", meaning: "A button, switch, tab, or menu: it does something.",
                feel: "One firm tick", symbol: "button.horizontal.top.press"),
        CueInfo(cue: .caution, name: "Caution", meaning: "A destructive action, a field with an error, or an alert.",
                feel: "Two strong pulses", symbol: "exclamationmark.triangle"),
        CueInfo(cue: .navigation, name: "Navigation", meaning: "The selected item in a sidebar, list, or tab strip changed.",
                feel: "One crisp tick", symbol: "sidebar.left"),
        CueInfo(cue: .landmark, name: "Heading", meaning: "A new section or post starts as it passes while you scroll.",
                feel: "One soft pulse", symbol: "text.justify.leading"),
        CueInfo(cue: .boundary, name: "Page end", meaning: "You reached the top or bottom; there's no more page that way.",
                feel: "A landing, a settle", symbol: "arrow.down.to.line"),
        CueInfo(cue: .waypoint, name: "Waypoint", meaning: "A find-in-page match, or highlighted text passing as you scroll (Safari and Chromium browsers).",
                feel: "A rising pair", symbol: "mappin.and.ellipse"),
        CueInfo(cue: .glide, name: "Glide", meaning: "You're scrolling fast. Pulses come closer as you speed up and fade as you slow.",
                feel: "Faint, spaced pulses", symbol: "wind"),
        CueInfo(cue: .swell, name: "Swell", meaning: "A quick burst of scrolling speed.",
                feel: "One soft swell", symbol: "gauge.with.dots.needle.67percent"),
    ]

    static func info(for cue: Cue) -> CueInfo? {
        all.first { $0.cue == cue }
    }
}
