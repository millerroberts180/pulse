import PulseCore
import QuartzCore
import SwiftUI

/// What each cue means, in the words the setup and Settings › Cues use.
struct CueInfo: Identifiable {
    var cue: Cue
    var name: String
    var meaning: String
    var feel: String
    var symbol: String
    var id: Cue { cue }

    /// Every cue, in the order the picker lines them up.
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

/// One cue: a pad that plays it as the pointer swipes onto it, its name and
/// feel, and whether it's on. The glide pad plays a whole fling: a swell, then
/// glides thinning out.
struct CueTile: View {
    var info: CueInfo
    var previewer: CuePreviewer
    @Binding var isOn: Bool
    var onFeel: (CueInfo) -> Void

    @State private var inside = false
    @State private var lit = false

    var body: some View {
        VStack(spacing: 7) {
            pad
            Text(info.name)
                .font(.system(size: 12, weight: .semibold))
            Text(info.feel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(height: 26, alignment: .top)
            Toggle("Use \(info.name)", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .frame(width: 80)
    }

    private var pad: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(
                colors: [Color.accentColor.opacity(isOn ? 0.30 : 0.10), Color.accentColor.opacity(isOn ? 0.12 : 0.04)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(lit ? 0.9 : (isOn ? 0.35 : 0.15)), lineWidth: lit ? 2 : 1)
            )
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: info.symbol)
                        .font(.system(size: 18, weight: .medium))
                    Image(systemName: "hand.draw")
                        .font(.system(size: 11))
                        .opacity(0.55)
                }
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            )
            .frame(width: 72, height: 96)
            .scaleEffect(lit ? 1.05 : 1)
            .contentShape(Rectangle())
            .onHover { entered in
                inside = entered
                if entered { feel() }
            }
            .onTapGesture { feel() }
            .help("Swipe over to feel the \(info.name.lowercased()) cue")
            .accessibilityElement()
            .accessibilityLabel("Feel \(info.name)")
            .accessibilityHint(info.meaning)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { feel() }
    }

    private func feel() {
        // A lone glide pulse means little; a fling shows what it's for.
        if info.cue == .glide { previewer.play(.glide) } else { previewer.feel(info.cue) }
        light()
        onFeel(info)
    }

    private func light() {
        withAnimation(.easeOut(duration: 0.08)) { lit = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.easeOut(duration: 0.35)) { lit = false }
        }
    }
}

/// Every cue in a line, to feel and to choose.
struct CuePicker: View {
    @ObservedObject var store: SettingsStore
    var previewer: CuePreviewer
    @State private var described: CueInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(CueInfo.all) { info in
                    CueTile(info: info, previewer: previewer, isOn: binding(for: info.cue)) { described = $0 }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let described {
                    Text(described.name).fontWeight(.semibold)
                    Text(described.meaning).foregroundStyle(.secondary)
                } else {
                    Text("Each cue's meaning appears here as you feel it.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .frame(minHeight: 32, alignment: .topLeading)
            .accessibilityElement(children: .combine)
        }
    }

    private func binding(for cue: Cue) -> Binding<Bool> {
        Binding(get: { store.value.isOn(cue) }, set: { store.value.set(cue, on: $0) })
    }
}
