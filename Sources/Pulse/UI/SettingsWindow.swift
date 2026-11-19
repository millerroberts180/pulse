import AppKit
import PulseCore
import SwiftUI

/// A plain window hosting one SwiftUI view, created on demand and kept
/// while Pulse runs so reopening it is instant.
final class HostedWindow<Content: View>: NSWindowController {
    /// `sidebar`: content runs under a transparent title bar, the way System
    /// Settings and other sidebar windows look.
    init(title: String, size: CGSize, sidebar: Bool = false, @ViewBuilder content: () -> Content) {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if sidebar { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        if sidebar {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        let hosting = NSHostingController(rootView: content())
        window.contentViewController = hosting
        // The window takes its size from the view only once the view loads.
        // Size it now, or center() centres an empty window and the real one
        // opens off to the right, up against the menu bar.
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // A menu-bar app's activation request can be declined while another
        // app is in use; the window still comes to the front.
        window?.orderFrontRegardless()
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, cues, motion, keyboard, quiet, about
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .cues: "Cues"
        case .motion: "Motion"
        case .keyboard: "Keyboard"
        case .quiet: "Quiet"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .cues: "hand.tap.fill"
        case .motion: "wind"
        case .keyboard: "keyboard.fill"
        case .quiet: "moon.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .cues: .blue
        case .motion: .teal
        case .keyboard: .orange
        case .quiet: .indigo
        case .about: .gray
        }
    }
}

struct SettingsView: View {
    static let size = CGSize(width: 620, height: 540)

    @ObservedObject var store: SettingsStore
    var previewer: CuePreviewer
    var releaseClickUnavailable: () -> Bool = { false }
    var onShowSetup: () -> Void = {}
    var onTestHaptic: () -> Void = {}
    var onTypingDemo: (Bool) -> Void = { _ in }
    @State var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    SidebarRow(pane: .general)
                }
                Section("Feedback") {
                    SidebarRow(pane: .cues)
                    SidebarRow(pane: .motion)
                    SidebarRow(pane: .keyboard)
                }
                Section("Privacy") {
                    SidebarRow(pane: .quiet)
                }
                Section("Pulse") {
                    SidebarRow(pane: .about)
                }
            }
            .listStyle(.sidebar)
            // Room between the title bar and the first pane. Content margins
            // would do the same, but only from the window's second update, so
            // General would open pressed against the window buttons.
            .safeAreaPadding(.top, 12)
            .navigationSplitViewColumnWidth(150)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                PaneHeader(pane: pane ?? .general)
                Divider().opacity(0.6)
                detail
            }
            .navigationTitle((pane ?? .general).title)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var detail: some View {
        switch pane ?? .general {
        case .general:
            GeneralPane(store: store, previewer: previewer, releaseClickUnavailable: releaseClickUnavailable(), onShowSetup: onShowSetup, onTestHaptic: onTestHaptic)
        case .cues: CuesPane(store: store, previewer: previewer)
        case .motion: MotionPane(store: store, previewer: previewer)
        case .keyboard: KeyboardPane(store: store, previewer: previewer, onTypingDemo: onTypingDemo)
        case .quiet: QuietPane(store: store)
        case .about: AboutPane()
        }
    }
}

/// What you're looking at, above the pane: its tile and its name.
private struct PaneHeader: View {
    var pane: SettingsPane

    var body: some View {
        HStack(spacing: 9) {
            PaneTile(pane: pane, size: 24)
            Text(pane.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A pane's tinted icon tile, for the sidebar and the header.
private struct PaneTile: View {
    var pane: SettingsPane
    var size: CGFloat

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(pane.tint.gradient))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// One pane in the sidebar: a tinted tile, then its name.
private struct SidebarRow: View {
    var pane: SettingsPane

    var body: some View {
        Label {
            Text(pane.title).font(.system(size: 12))
        } icon: {
            PaneTile(pane: pane, size: 19)
        }
        .padding(.vertical, 1)
        .tag(pane)
    }
}

/// A switch with a second, quieter line of explanation.
private struct DetailToggle: View {
    var title: String
    var detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    var previewer: CuePreviewer
    var releaseClickUnavailable: Bool
    var onShowSetup: () -> Void
    var onTestHaptic: () -> Void
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.needsApproval

    var body: some View {
        Form {
            Section {
                DetailToggle(title: "Mute Pulse", detail: "Or press \(MuteHotKey.display) anywhere.", isOn: $store.value.muted)
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        LoginItem.set(on)
                        openAtLogin = LoginItem.isEnabled
                        needsApproval = LoginItem.needsApproval
                    }
                if needsApproval {
                    Text("Allow Pulse in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Trackpad") {
                Toggle("Haptic feedback", isOn: $store.value.hapticsEnabled)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Strength")
                    // Picking one plays a control's tick at that strength.
                    VisualChoice(options: [
                        .init(value: Float(0.7), title: "Gentle", art: .pulse(level: 0.25)),
                        .init(value: Float(1), title: "Standard", art: .pulse(level: 0.5)),
                        .init(value: Float(1.3), title: "Firm", art: .pulse(level: 0.75)),
                        .init(value: Float(1.8), title: "Strong", art: .pulse(level: 1)),
                    ], selection: $store.value.hapticStrength) { _ in previewer.feel(.action) }
                }
                .padding(.vertical, 2)
                .disabled(!store.value.hapticsEnabled)
                DetailToggle(
                    title: "Click once, on press",
                    detail: releaseClickUnavailable && store.value.silenceReleaseClick
                        ? "This trackpad's release click can't be changed."
                        : "Silences the trackpad's second click as you let go. Pulse puts it back when it quits.",
                    isOn: $store.value.silenceReleaseClick
                )
                .disabled(!store.value.hapticsEnabled)
                LabeledContent("Check the trackpad") {
                    Button(action: onTestHaptic) { PulseActionLabel(title: "Test Feedback", icon: .pulse) }
                        .buttonStyle(PulseActionButtonStyle())
                }
            }
            Section("Sound") {
                LabeledContent("Cue volume") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $store.value.cueVolume, in: 0...1).frame(width: 200)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                DetailToggle(
                    title: "Tones for page cues",
                    detail: store.value.hapticsEnabled
                        ? "A quiet tone alongside headings, navigation, cautions, and page ends."
                        : "Audio-only: with haptic feedback off, every page cue is a tone.",
                    isOn: $store.value.pageSounds
                )
            }
            Section {
                LabeledContent("Learn the cues again") {
                    Button(action: onShowSetup) { PulseActionLabel(title: "Open Tutorial…", icon: .symbol("sparkles")) }
                        .buttonStyle(PulseActionButtonStyle())
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CuesPane: View {
    @ObservedObject var store: SettingsStore
    var previewer: CuePreviewer

    var body: some View {
        Form {
            Section {
                ForEach(CueInfo.all.filter { ![.glide, .swell, .waypoint].contains($0.cue) }) { row($0) }
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Every cue means one thing. With a finger on the trackpad, swipe over an icon to feel it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .textCase(nil)
                    Text("On the page")
                }
            } footer: {
                Text("Cues come from what each app exposes to Accessibility; pages without structure are Motion-only.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Scrolling fast") {
                ForEach(CueInfo.all.filter { [.glide, .swell].contains($0.cue) }) { row($0) }
            }
            Section {
                if let waypoint = CueInfo.info(for: .waypoint) { row(waypoint) }
            } header: {
                Text("Optional")
            } footer: {
                Text("Find-in-page matches in Safari and Chromium browsers, and highlighted text in Safari. Firefox and Zen don't report either.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ info: CueInfo) -> some View {
        HStack(spacing: 12) {
            CueSwatch(info: info, previewer: previewer)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.name)
                    Text(info.feel).font(.caption).foregroundStyle(.tertiary)
                }
                Text(info.meaning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Use \(info.name)", isOn: Binding(
                get: { store.value.isOn(info.cue) },
                set: { store.value.set(info.cue, on: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

/// A cue's icon, which plays the cue as the pointer swipes onto it (or on
/// a click), and lights up as it does.
private struct CueSwatch: View {
    var info: CueInfo
    var previewer: CuePreviewer
    @State private var lit = false

    var body: some View {
        Image(systemName: info.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(lit ? 0.34 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(lit ? 0.8 : 0), lineWidth: 1.5))
            .scaleEffect(lit ? 1.08 : 1)
            .contentShape(Rectangle())
            .onHover { if $0 { feel() } }
            .onTapGesture { feel() }
            .help("Swipe over to feel the \(info.name.lowercased()) cue")
            .accessibilityElement()
            .accessibilityLabel("Feel \(info.name)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { feel() }
    }

    private func feel() {
        if info.cue == .glide { previewer.play(.glide) } else { previewer.feel(info.cue) }
        withAnimation(.easeOut(duration: 0.08)) { lit = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.easeOut(duration: 0.35)) { lit = false }
        }
    }
}

private struct MotionPane: View {
    @ObservedObject var store: SettingsStore
    var previewer: CuePreviewer

    var body: some View {
        Form {
            Section {
                DetailToggle(title: "Feel motion", detail: "Glides and swells on the trackpad, while your fingers are on it.", isOn: $store.value.motionHaptics)
                    .disabled(!store.value.hapticsEnabled)
                DetailToggle(title: "Hear motion", detail: "A soft sound layer, which also carries momentum after your fingers lift and mouse-wheel scrolling.", isOn: $store.value.motionSounds)
            } footer: {
                Text("Careful scrolling is always silent. Choose which motion cues to use in Cues.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Response") {
                // Picking either plays a fling with exactly that tuning.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Starts")
                    VisualChoice(options: [
                        .init(value: MotionThreshold.early, title: "Early", art: .threshold(start: 0.22)),
                        .init(value: MotionThreshold.standard, title: "Standard", art: .threshold(start: 0.42)),
                        .init(value: MotionThreshold.late, title: "Fast flicks only", art: .threshold(start: 0.66)),
                    ], selection: $store.value.motionThreshold) { _ in previewer.play(.glide) }
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Intensity")
                    VisualChoice(options: [
                        .init(value: MotionIntensity.subtle, title: "Subtle", art: .density(level: 0)),
                        .init(value: MotionIntensity.standard, title: "Standard", art: .density(level: 0.5)),
                        .init(value: MotionIntensity.lively, title: "Lively", art: .density(level: 1)),
                    ], selection: $store.value.motionIntensity) { _ in previewer.play(.glide) }
                }
                .padding(.vertical, 2)
                LabeledContent("Preview") {
                    Button { previewer.play(.glide) } label: { PulseActionLabel(title: "Feel a Fling", icon: .symbol("wind")) }
                        .buttonStyle(PulseActionButtonStyle())
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyboardPane: View {
    @ObservedObject var store: SettingsStore
    var previewer: CuePreviewer
    var onTypingDemo: (Bool) -> Void

    var body: some View {
        Form {
            Section("Typing sound") {
                KeyboardPicker(store: store, previewer: previewer, tileWidth: 90, compact: true)
                    .padding(.vertical, 6)
            }
            if [.mechanical, .ambient].contains(store.value.keyboardProfile) {
                Section("Board") {
                    BoardPicker(store: store, previewer: previewer)
                        .padding(.vertical, 4)
                }
            }
            Section {
                KeyboardDemo(store: store, previewer: previewer, size: .small, onActive: onTypingDemo)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } header: {
                Text("Try it")
            } footer: {
                Text("Type, or click the keys. Only key positions are used, never what you type.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $store.value.keyboardVolume, in: 0...1).frame(width: 200)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(!store.value.keyboardEnabled || store.value.keyboardProfile == .quiet)
                DetailToggle(title: "Key release sounds", detail: "Mechanical's lighter up-stroke as each key comes back.", isOn: $store.value.keyReleaseSounds)
                DetailToggle(title: "Repeat warning", detail: "A distinct cue when a held key starts repeating, sooner for Delete.", isOn: $store.value.repeatWarnings)
                DetailToggle(title: "Feel Caps Lock and shortcuts", detail: "Trackpad equivalents of KeySense's state cues, so none is sound-only.", isOn: $store.value.keyboardHaptics)
            }
        }
        .formStyle(.grouped)
    }
}

private struct QuietPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Pulse's sounds go quiet") {
                Toggle("While the microphone is in use", isOn: $store.value.quietWhileMicrophoneInUse)
                DetailToggle(
                    title: "While another app plays audio",
                    detail: MediaMonitor.isSupported ? "Music, video, or the other side of a call. Haptics carry on." : "Needs macOS 14.2 or later.",
                    isOn: $store.value.quietWhileMediaPlays
                )
                .disabled(!MediaMonitor.isSupported)
            }
            Section("Always") {
                Label("Silent in password fields", systemImage: "lock.fill")
                Label("Keyboard sound stays off while VoiceOver runs, until you choose a profile", systemImage: "accessibility")
            }
            .foregroundStyle(.secondary)
            Section {
                if store.value.excludedApps.isEmpty {
                    Text("No apps. Bring one to the front and choose Turn Off in its name from the menu bar.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.value.excludedApps.sorted(), id: \.self) { id in
                        HStack(spacing: 10) {
                            Image(nsImage: Self.icon(for: id))
                                .resizable()
                                .frame(width: 22, height: 22)
                            Text(Self.name(for: id))
                            Spacer()
                            Button { store.value.excludedApps.remove(id) } label: {
                                PulseActionLabel(title: "Turn On", icon: .symbol("power"))
                            }
                            .buttonStyle(PulseActionButtonStyle(compact: true))
                        }
                    }
                }
            } header: {
                Text("Turned off in")
            }
        }
        .formStyle(.grouped)
    }

    private static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct AboutPane: View {
    private var version: String {
        guard let version = ReleaseInfo.version else { return "Development build" }
        return "Version \(version.short)" + (version.build.map { " (\($0))" } ?? "")
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: PulseLogo.iconImage(size: 64))
                        .accessibilityHidden(true)
                    Text("Pulse")
                        .font(.system(size: 20, weight: .semibold))
                    Text(version)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Feel web pages through your trackpad, and hear your typing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !ReleaseInfo.copyright.isEmpty {
                        Text(ReleaseInfo.copyright)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }

            Section {
                LabeledContent("Website") {
                    Link(ReleaseInfo.websiteURL.host() ?? ReleaseInfo.websiteURL.absoluteString, destination: ReleaseInfo.websiteURL)
                }
                LabeledContent("Support") {
                    Link(ReleaseInfo.supportTitle, destination: ReleaseInfo.supportURL ?? ReleaseInfo.supportMailURL)
                }
                LabeledContent("Privacy policy") {
                    Link("Read", destination: ReleaseInfo.privacyPolicyURL)
                }
                LabeledContent("Licence agreement") {
                    Link("Read", destination: ReleaseInfo.eulaURL)
                }
            } header: {
                Text("Links")
            } footer: {
                Text("They open in \(ReleaseInfo.linksOpenIn). Pulse itself has no account and never goes online, and it never keeps page text, URLs or what you type.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}
