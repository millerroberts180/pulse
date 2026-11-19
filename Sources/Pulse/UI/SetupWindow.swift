import AppKit
import ApplicationServices
import PulseCore
import SwiftUI

/// The setup: a tour page where every cue happens as you point at it and
/// scroll it, the one permission, the typing sound to try by typing for
/// real, and the menu bar, the mute shortcut, and open at login. Opened
/// again later, it's the tutorial: the same steps without the permission
/// and open at login.
@MainActor
final class SetupModel: ObservableObject {
    let tutorialOnly: Bool
    /// The steps this run shows.
    let steps: [SetupStep]
    @Published var step: SetupStep
    @Published var trusted = AXIsProcessTrusted()
    @Published var openAtLogin = true
    @Published var tour = TourChecklist()
    /// Live typing's state, so the typing step can say why it's silent.
    @Published var keyboard: KeyboardController.Status

    let store: SettingsStore
    let previewer: CuePreviewer
    var onFinish: (() -> Void)?
    var onRequestPermission: (() -> Void)?

    private var trustTimer: Timer?

    init(store: SettingsStore, previewer: CuePreviewer, tutorialOnly: Bool = false, keyboard: KeyboardController.Status = .off) {
        self.store = store
        self.previewer = previewer
        self.tutorialOnly = tutorialOnly
        self.keyboard = keyboard
        steps = SetupStep.steps(tutorialOnly: tutorialOnly)
        step = steps[0]
        openAtLogin = LoginItem.isEnabled || !UserDefaults.standard.bool(forKey: SetupWindowController.completedKey)
    }

    var isFirst: Bool { step == steps.first }
    var isLast: Bool { step == steps.last }

    func next() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return finish() }
        step = steps[index + 1]
        if step == .permission { watchTrust() }
        if step == .typing { trusted = AXIsProcessTrusted() }
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }

    func finish() {
        trustTimer?.invalidate()
        trustTimer = nil
        if !tutorialOnly, openAtLogin != LoginItem.isEnabled { LoginItem.set(openAtLogin) }
        onFinish?()
    }

    func requestPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        onRequestPermission?()
        watchTrust()
    }

    /// A cue from the tour. It ticks off only if it played (one action, one
    /// cue) with a finger on the trackpad: momentum after a flick is travel
    /// you can't feel.
    func toured(_ cue: Cue, feel: Bool, level: Float) {
        guard previewer.practice(cue, feel: feel, level: level) else { return }
        tour.played(cue, felt: feel)
    }

    func keyboardChanged(_ status: KeyboardController.Status) {
        keyboard = status
        // Typing starts once the grant lands.
        trusted = AXIsProcessTrusted()
    }

    private func watchTrust() {
        trusted = AXIsProcessTrusted()
        guard trustTimer == nil, !trusted else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trusted = AXIsProcessTrusted()
                if self.trusted {
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    static let completedKey = "setup.completed"
    static let size = CGSize(width: 840, height: 600)
    static let style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]

    private let model: SetupModel
    var onClose: (() -> Void)?

    init(
        store: SettingsStore, previewer: CuePreviewer, tutorialOnly: Bool, keyboard: KeyboardController.Status,
        onRequestPermission: @escaping () -> Void
    ) {
        model = SetupModel(store: store, previewer: previewer, tutorialOnly: tutorialOnly, keyboard: keyboard)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: Self.style,
            backing: .buffered, defer: false
        )
        window.title = tutorialOnly ? "Pulse Tutorial" : "Set Up Pulse"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: SetupView(model: model, store: store))
        window.contentViewController = hosting
        // Sized before centring, like Settings (see `HostedWindow`).
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        model.onRequestPermission = onRequestPermission
        model.onFinish = { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            self?.close()
        }
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

    func keyboardChanged(_ status: KeyboardController.Status) {
        model.keyboardChanged(status)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .tour: tour
                case .permission: narrow { permission }
                case .typing: typing
                case .done: narrow { done }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 34)

            Divider()
            HStack {
                progress
                Spacer()
                if !model.isFirst {
                    Button("Back") { model.back() }
                }
                // Return belongs to the typing box while it's up.
                Button(model.isLast ? (model.tutorialOnly ? "Done" : "Start Using Pulse") : "Continue") { model.next() }
                    .keyboardShortcut(model.step == .typing ? nil : .defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: SetupWindowController.size.width, height: SetupWindowController.size.height)
    }

    /// Reading-width steps sit centred in the wide window.
    private func narrow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: 600, alignment: .leading)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(model.steps, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \((model.steps.firstIndex(of: model.step) ?? 0) + 1) of \(model.steps.count)")
    }

    private func title(_ text: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 22, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }

    // MARK: - Steps

    private var tour: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: PulseLogo.iconImage(size: 44))
                    .accessibilityHidden(true)
                title("Feel the page", "Pulse taps the trackpad to tell you what's under the pointer and where you are on a page. Point at things on this page, then scroll it.")
            }
            TourPage { cue, feel, level in model.toured(cue, feel: feel, level: level) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
                .frame(height: 360)
            checklist
                .padding(.top, 12)
        }
    }

    /// Which cues the tour has played so far, and the latest one's meaning:
    /// what was felt, also said.
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(CueInfo.all) { info in
                    let felt = model.tour.felt.contains(info.cue)
                    HStack(spacing: 4) {
                        Image(systemName: felt ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                        Text(info.name).font(.system(size: 11, weight: felt ? .semibold : .regular))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(felt ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08)))
                    .foregroundStyle(felt ? Color.accentColor : Color.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(info.name), \(felt ? "felt" : "not yet felt")")
                }
            }
            Group {
                if let cue = model.tour.latest, let info = CueInfo.info(for: cue) {
                    Text("\(info.name): ").fontWeight(.semibold) + Text(info.meaning)
                } else {
                    Text("Cues are named here as you feel them.")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Allow Accessibility access", "Pulse needs it to find links, buttons and headings in other apps, and for typing sounds, which come next.")
            Label("Pulse never keeps page text, URLs, form values or what you type, and nothing is recorded or sent.", systemImage: "lock")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            if model.trusted {
                Label("Accessibility access is on.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Button("Open System Settings…") { model.requestPermission() }
                Text("Turn Pulse on in Privacy & Security › Accessibility. This page notices when you do. You can also do it later with Grant Access… in Pulse's menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Choose a typing sound", "Pick one, then type in the box to hear it. The board, volume and the rest are in Settings › Keyboard.")
            KeyboardPicker(store: store, previewer: model.previewer, tileWidth: 186)
            TypingField()
                .padding(.top, 18)
            if let note = typingNote {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    /// Why typing in the box makes no sound, when it doesn't, in the menu's words.
    private var typingNote: String? {
        guard model.trusted else { return "Typing sounds need Accessibility access. Turn it on with Grant Access… in Pulse's menu." }
        if model.keyboard == .mutedByUser { return "Pulse is muted. Press \(MuteHotKey.display) to unmute it." }
        return MenuController.keyboardQuietLine(model.keyboard)
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("You're set")
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Pulse lives in the menu bar. Its menu can mute Pulse, turn it off in the app you're using, and open Settings.")
                } icon: {
                    Image(nsImage: PulseLogo.statusImage(muted: false))
                }
                Label("Press \(MuteHotKey.display) anywhere to mute or unmute Pulse.", systemImage: "keyboard")
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)
            if !model.tutorialOnly {
                Toggle("Open Pulse at login", isOn: $model.openAtLogin)
                    .toggleStyle(.checkbox)
            }
        }
    }
}

/// A box to type in. Live typing plays the sound, through the same key tap
/// as in any other app. What's typed is only in the box, and gone with it.
private struct TypingField: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 84)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            .focused($focused)
            .accessibilityLabel("Type here to hear the typing sound")
            .onAppear { focused = true }
    }
}
