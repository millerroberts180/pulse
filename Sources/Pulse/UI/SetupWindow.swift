import AppKit
import ApplicationServices
import PulseCore
import SwiftUI

/// The interactive setup: what Pulse is, a tour page where every cue happens
/// as you swipe down it, then every cue in a line to feel again and switch on
/// or off, the typing sound on a keyboard to try, the one permission, and
/// open at login. Opened again later, it's only the tutorial: tour, cues,
/// and typing.
@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, tour, cues, typing, permission, done
    }

    /// The steps this run shows.
    let steps: [Step]
    @Published var step: Step
    @Published var trusted = AXIsProcessTrusted()
    @Published var openAtLogin = true
    /// Cues felt on the tour, for its checklist.
    @Published var felt: Set<Cue> = []
    @Published var lastTourCue: Cue?

    let store: SettingsStore
    let previewer: CuePreviewer
    var onFinish: (() -> Void)?
    var onRequestPermission: (() -> Void)?
    var onTypingDemo: (Bool) -> Void = { _ in }

    private var trustTimer: Timer?

    init(store: SettingsStore, previewer: CuePreviewer, tutorialOnly: Bool = false) {
        self.store = store
        self.previewer = previewer
        steps = tutorialOnly ? [.tour, .cues, .typing] : Step.allCases
        step = steps[0]
        openAtLogin = LoginItem.isEnabled || !UserDefaults.standard.bool(forKey: SetupWindowController.completedKey)
    }

    var isFirst: Bool { step == steps.first }
    var isLast: Bool { step == steps.last }

    func next() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return finish() }
        step = steps[index + 1]
        if step == .permission { watchTrust() }
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }

    func finish() {
        trustTimer?.invalidate()
        trustTimer = nil
        if steps.contains(.done), openAtLogin != LoginItem.isEnabled { LoginItem.set(openAtLogin) }
        onFinish?()
    }

    func requestPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        onRequestPermission?()
        watchTrust()
    }

    /// A cue from the tour. It counts as felt only if a finger was on the
    /// trackpad: momentum after a flick is travel you can't feel.
    func toured(_ cue: Cue, feel: Bool, level: Float) {
        previewer.practice(cue, feel: feel, level: level)
        if feel { felt.insert(cue) }
        lastTourCue = cue
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
        store: SettingsStore, previewer: CuePreviewer, tutorialOnly: Bool,
        onRequestPermission: @escaping () -> Void, onTypingDemo: @escaping (Bool) -> Void
    ) {
        model = SetupModel(store: store, previewer: previewer, tutorialOnly: tutorialOnly)
        model.onTypingDemo = onTypingDemo
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

    func windowWillClose(_ notification: Notification) {
        // Closing on the typing step must give live typing its sound back.
        model.onTypingDemo(false)
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
                case .welcome: narrow { welcome }
                case .tour: tour
                case .cues: cues
                case .typing: typing
                case .permission: narrow { permission }
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
                Button(model.isLast ? (model.step == .done ? "Start Using Pulse" : "Done") : "Continue") { model.next() }
                    .keyboardShortcut(.defaultAction)
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

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: PulseLogo.iconImage(size: 64))
                .accessibilityHidden(true)
                .padding(.bottom, 10)
            title("Welcome to Pulse", "A quiet physical language for browsing and typing. Small trackpad cues tell you about the page; nothing pulses while you read.")
            feature("hand.tap", "Feel the page", "Headings, links, controls, cautions, and page ends, from what macOS Accessibility exposes. No browser extension.")
            feature("wind", "Motion scrolling", "Silent when you scroll carefully; a sparse glide when you travel fast.")
            feature("keyboard", "Typing sound", "Warm key sounds, or KeySense: quiet cues that confirm keys without saying what you typed.")
            feature("lock", "Private by design", "Pulse never keeps page text, URLs, form values, or what you type, and nothing leaves your Mac.")
            Text("Next, a short tour page: swipe down it to meet every cue.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private func feature(_ symbol: String, _ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 14)
    }

    private var tour: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Take the tour", "Swipe down slowly with two fingers. Each section plays its cue as it crosses the line, and its part of the page lights up.")
            FakeBrowser {
                TourPage { cue, feel, level in model.toured(cue, feel: feel, level: level) }
            }
            .frame(height: 344)
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
                    let felt = model.felt.contains(info.cue)
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
                if let cue = model.lastTourCue, let info = CueInfo.info(for: cue) {
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

    private var cues: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Choose your cues", "Every cue, in a line. Swipe over a pad to feel it, and switch off any you don't want. You can change these later in Settings.")
            CuePicker(store: store, previewer: model.previewer)
            Text("Waypoints start off: they're for find-in-page matches, which Safari and Chromium browsers report, and highlighted text, which only Safari does.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
        }
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Choose a typing sound", "Pick one, then type or click the keys to hear it. Pulse hears key groups, never characters.")
            HStack(alignment: .top, spacing: 18) {
                KeyboardPicker(store: store, previewer: model.previewer, tileWidth: 92, compact: true)
                if [.mechanical, .ambient].contains(store.value.keyboardProfile) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Board").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        BoardPicker(store: store, previewer: model.previewer, compact: true)
                    }
                }
            }
            KeyboardDemo(store: store, previewer: model.previewer, onActive: model.onTypingDemo)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $store.value.keyboardVolume, in: 0...1).frame(width: 130)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                Toggle("Release sounds", isOn: $store.value.keyReleaseSounds)
                Toggle("Feel Caps Lock and shortcuts", isOn: $store.value.keyboardHaptics)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("One permission", "Pulse needs Accessibility access to recognise controls and headings in other apps, and to notice key presses for typing sounds.")
            VStack(alignment: .leading, spacing: 8) {
                Label("Reads roles, states, and positions: \"a button\", \"a heading at this height\".", systemImage: "checkmark.circle")
                Label("Never keeps page text, URLs, form values, or what you type.", systemImage: "checkmark.circle")
                Label("Nothing is recorded or sent anywhere.", systemImage: "checkmark.circle")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)

            if model.trusted {
                Label("Accessibility access is on.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Button("Open System Settings…") { model.requestPermission() }
                Text("Turn Pulse on in Privacy & Security › Accessibility. This page notices when you do. You can also continue and do it later from the menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("You're set", "Pulse lives in the menu bar. It stays quiet in password fields, while the microphone or other audio is in use, and in apps you turn it off for.")
            VStack(alignment: .leading, spacing: 10) {
                Label("Mute everything with \(MuteHotKey.display).", systemImage: "hand.raised.slash")
                Label("Feel any cue again, or switch it off, in Settings › Cues.", systemImage: "hand.tap")
                Label("Fine-tune motion and sound in Settings.", systemImage: "slider.horizontal.3")
            }
            .font(.system(size: 13))
            .padding(.bottom, 20)
            Toggle("Open Pulse at login", isOn: $model.openAtLogin)
                .toggleStyle(.checkbox)
        }
    }
}

/// A plain browser frame around the tour, so it reads as a web page, with
/// the cue line marked a third of the way down the page.
private struct FakeBrowser<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.55)).frame(width: 9, height: 9)
                }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text("pulse.tour/everything-you-can-feel").font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                Spacer()
                Color.clear.frame(width: 39, height: 9)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.secondary.opacity(0.08))
            .accessibilityHidden(true)

            content
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        let y = geometry.size.height * TourScrollView.cueLine
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        Text("cue line")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                            .position(x: geometry.size.width - 34, y: y - 8)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
    }
}
