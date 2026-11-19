import PulseCore
import SwiftUI

/// The typing sounds, as tiles like the cue picker's: one to choose, each
/// with a play button to hear a short phrase typed with it.
struct KeyboardPicker: View {
    @ObservedObject var store: SettingsStore
    var previewer: CuePreviewer
    var tileWidth: CGFloat = 168
    /// Name only under each pad, with the chosen profile described below the
    /// row: for narrow places like Settings.
    var compact = false

    struct Profile: Identifiable {
        var profile: KeyboardProfile
        var name: String
        var detail: String
        var symbol: String
        var id: KeyboardProfile { profile }
    }

    static let profiles: [Profile] = [
        Profile(profile: .ambient, name: "Ambient", detail: "One quiet, even sound that stays behind your typing.", symbol: "water.waves"),
        Profile(profile: .mechanical, name: "Mechanical", detail: "A real keyboard, every key group its own sound, on the board you choose.", symbol: "keyboard"),
        Profile(profile: .keySense, name: "KeySense", detail: "Distinct quiet cues for letters, Return, Delete, shortcuts, and Caps Lock.", symbol: "waveform"),
        Profile(profile: .quiet, name: "Quiet", detail: "No typing sound.", symbol: "speaker.slash"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Self.profiles) { profile in
                    tile(profile)
                }
            }
            if compact, let chosen = Self.profiles.first(where: { isSelected($0.profile) }) {
                Text(chosen.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isSelected(_ profile: KeyboardProfile) -> Bool {
        let settings = store.value
        return profile == .quiet
            ? !settings.keyboardEnabled || settings.keyboardProfile == .quiet
            : settings.keyboardEnabled && settings.keyboardProfile == profile
    }

    private func choose(_ profile: KeyboardProfile) {
        store.value.keyboardProfile = profile
        store.value.keyboardProfileChosen = true
        if profile != .quiet { store.value.keyboardEnabled = true }
    }

    private func tile(_ profile: Profile) -> some View {
        let selected = isSelected(profile.profile)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(selected ? 0.32 : 0.08), Color.accentColor.opacity(selected ? 0.12 : 0.03)],
                        startPoint: .top, endPoint: .bottom
                    ))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
                Image(systemName: profile.symbol)
                    .font(.system(size: compact ? 20 : 26, weight: .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .frame(height: compact ? 64 : 92)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: compact ? 13 : 15))
                        .foregroundStyle(Color.white, Color.accentColor)
                        .padding(compact ? 5 : 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if profile.profile != .quiet {
                    Button {
                        previewer.audition(profile.profile)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: compact ? 8 : 10, weight: .bold))
                            .frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .padding(compact ? 5 : 8)
                    .help("Listen to \(profile.name)")
                    .accessibilityLabel("Listen to \(profile.name)")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { choose(profile.profile) }

            Text(profile.name)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
            if !compact {
                Text(profile.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: tileWidth, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profile.name)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose(profile.profile) }
    }
}

/// Which keyboard Mechanical (and Ambient) sound like, as tiles drawing each
/// board's tone: the energy across its bands as a key strikes.
struct BoardPicker: View {
    @ObservedObject var store: SettingsStore
    var previewer: CuePreviewer
    var compact = false

    static func name(_ board: KeyboardBoard) -> String {
        switch board {
        case .creamy: "Creamy"
        case .velvet: "Velvet"
        case .citrus: "Citrus"
        case .alloy: "Alloy"
        case .crisp: "Crisp"
        }
    }

    static func detail(_ board: KeyboardBoard) -> String {
        switch board {
        case .creamy: "Soft, muted, and short: the classic creamy linear."
        case .velvet: "Smoother still, with almost no edge."
        case .citrus: "Like Creamy, with a little more pop."
        case .alloy: "A heavier aluminium board with a longer ring."
        case .crisp: "Brighter and clackier, with more low end."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(KeyboardBoard.allCases, id: \.self) { board in tile(board) }
            }
            if !compact {
                Text(Self.detail(store.value.keyboardBoard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ board: KeyboardBoard) -> some View {
        let selected = store.value.keyboardBoard == board
        return Button {
            store.value.keyboardBoard = board
            // The bank re-renders as the setting changes, so this plays the new board.
            previewer.audition(store.value.keyboardProfile == .ambient ? .ambient : .mechanical)
        } label: {
            VStack(spacing: 5) {
                SignatureBars(levels: board.signature, highlighted: selected)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 26 : 34)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(selected ? 0.10 : 0.05)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1)
                    )
                    .shadow(color: selected ? Color.accentColor.opacity(0.45) : .clear, radius: 5)
                Text(Self.name(board))
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.detail(board))
        .accessibilityLabel("\(Self.name(board)) board")
        .accessibilityHint(Self.detail(board))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A board's tone as bars, low to high frequency.
private struct SignatureBars: View {
    var levels: [Double]
    var highlighted: Bool

    var body: some View {
        Canvas { context, size in
            let count = CGFloat(levels.count)
            let gap: CGFloat = 2
            let width = max((size.width - gap * (count - 1)) / count, 1)
            for (index, level) in levels.enumerated() {
                let height = max(size.height * level, 2)
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                             with: .color(highlighted ? Color.accentColor : Color.secondary.opacity(0.6)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The keyboard switches that go with the picker, in one tidy group.
struct KeyboardOptions: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            row("Volume") {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $store.value.keyboardVolume, in: 0...1)
                    .frame(width: 200)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            Divider()
            row("Key release sounds (Mechanical)") {
                Toggle("", isOn: $store.value.keyReleaseSounds).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider()
            row("Feel Caps Lock and shortcuts on the trackpad") {
                Toggle("", isOn: $store.value.keyboardHaptics).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12))
            Spacer(minLength: 20)
            control()
        }
        .frame(height: 38)
    }
}
