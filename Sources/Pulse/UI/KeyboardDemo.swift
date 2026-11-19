import AppKit
import PulseCore
import SwiftUI

/// A Mac keyboard on screen, to try the typing sounds the way Mechvibes'
/// "Try it" does: type on the real keyboard or click the keys, and each one
/// lights up and sounds with the chosen profile, through the same key
/// interpretation as live typing (groups, chords, Caps Lock, repeats).
///
/// Only key codes are used, to light the key and pick its group; what's
/// typed isn't shown, kept, or sent. It listens only while its own window is
/// in front, and then Pulse's live typing sound stands aside so nothing plays
/// twice.
struct KeyboardDemo: View {
    enum Size {
        /// The setup's typing step.
        case regular
        /// Settings › Keyboard.
        case small

        var unit: CGFloat { self == .regular ? 33 : 22 }
        var gap: CGFloat { self == .regular ? 4 : 3 }
    }

    @StateObject private var model: TypingDemoModel
    private let size: Size

    init(store: SettingsStore, previewer: CuePreviewer, size: Size = .regular, onActive: @escaping (Bool) -> Void) {
        self.size = size
        _model = StateObject(wrappedValue: TypingDemoModel(store: store, previewer: previewer, onActive: onActive))
    }

    var body: some View {
        VStack(spacing: size.gap) {
            ForEach(Array(KeyCap.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: size.gap) {
                    ForEach(row) { key in
                        if key.code == KeyCap.arrowCluster {
                            arrows
                        } else {
                            keyView(key, height: size.unit)
                        }
                    }
                }
            }
        }
        .padding(size == .regular ? 10 : 8)
        .background(
            RoundedRectangle(cornerRadius: size == .regular ? 14 : 11, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: size == .regular ? 14 : 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .background(WindowReader { model.attach(to: $0) })
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard to try the typing sound. Type, or click the keys.")
    }

    /// ← ↑↓ →, with Up and Down half height, stacked, as on a Mac.
    private var arrows: some View {
        HStack(spacing: size.gap) {
            keyView(KeyCap(code: 123, label: "←"), height: size.unit)
            VStack(spacing: 2) {
                keyView(KeyCap(code: 126, label: "↑"), height: (size.unit - 2) / 2)
                keyView(KeyCap(code: 125, label: "↓"), height: (size.unit - 2) / 2)
            }
            keyView(KeyCap(code: 124, label: "→"), height: size.unit)
        }
    }

    private func keyView(_ key: KeyCap, height: CGFloat) -> some View {
        let down = model.pressed.contains(key.code) || (key.code == KeyClassifier.capsLockKeyCode && model.capsLock)
        let width = key.width * size.unit + (key.width - 1) * size.gap
        let label = size == .small ? key.shortLabel : key.label
        let wordy = label.count > 2
        let radius: CGFloat = size == .regular ? 6 : 4.5
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(down ? Color.accentColor.opacity(0.38) : Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(down ? 0 : 0.22), radius: 0, x: 0, y: down ? 0 : (size == .regular ? 1.5 : 1))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(down ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: down ? 1.5 : 1)
            Text(label)
                .font(.system(size: size == .regular ? (wordy ? 9 : 11) : (wordy ? 7 : 9), weight: .medium))
                .foregroundStyle(down ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wordy && key.width > 1.4 ? .bottomLeading : .center)
                .padding(wordy && key.width > 1.4 ? (size == .regular ? 5 : 3) : 0)
        }
        .frame(width: width, height: height)
        .offset(y: down ? (size == .regular ? 1.5 : 1) : 0)
        .shadow(color: down ? Color.accentColor.opacity(0.5) : .clear, radius: size == .regular ? 5 : 3)
        .animation(.easeOut(duration: 0.06), value: down)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in model.click(key.code, down: true) }
                .onEnded { _ in model.click(key.code, down: false) }
        )
        .accessibilityElement()
        .accessibilityLabel(key.spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            model.click(key.code, down: true)
            model.click(key.code, down: false)
        }
    }
}

/// Hands the hosting window to the demo once the view is in one.
private struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Lights keys and plays them, from the real keyboard while the demo's window
/// is in front, and from clicks.
@MainActor
final class TypingDemoModel: ObservableObject {
    @Published var pressed: Set<UInt16> = []
    @Published var capsLock = false

    private let store: SettingsStore
    private let previewer: CuePreviewer
    private let onActive: (Bool) -> Void
    private var interpreter = KeyInterpreter()
    private var monitor: Any?
    private var clicked: Set<UInt16> = []
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    /// Listening, and Pulse's live typing sound stood aside.
    private(set) var isActive = false

    #if DEBUG
    /// The self-test drives it from a window that can't become key.
    var ignoresKeyWindow = false
    #endif

    init(store: SettingsStore, previewer: CuePreviewer, onActive: @escaping (Bool) -> Void) {
        self.store = store
        self.previewer = previewer
        self.onActive = onActive
    }

    /// The demo is live while its window is the key window, and only then.
    func attach(to window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActive() }
            }
        }
        updateActive()
    }

    func start() {
        guard monitor == nil else { return }
        let flags = NSEvent.modifierFlags
        interpreter = KeyInterpreter(modifiers: Self.modifiers(flags))
        capsLock = flags.contains(.capsLock)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread, and the event stays on it.
            nonisolated(unsafe) let event = event
            let passOn = MainActor.assumeIsolated { self?.handle(event) ?? true }
            return passOn ? event : nil
        }
        updateActive()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressed = []
        clicked = []
        updateActive()
    }

    private var listening: Bool {
        guard monitor != nil, let window else { return false }
        #if DEBUG
        if ignoresKeyWindow { return true }
        #endif
        return window.isKeyWindow && window.isVisible
    }

    private func updateActive() {
        let active = listening
        guard active != isActive else { return }
        isActive = active
        if !active { pressed = [] }
        onActive(active)
    }

    /// The real keyboard. Returns whether the event goes on to the app: other
    /// windows' keys always do, and here only ⌘ shortcuts (⌘W, ⌘Q), so
    /// Return doesn't press Continue.
    func handle(_ event: NSEvent) -> Bool {
        guard listening, event.windowNumber == window?.windowNumber else { return true }
        let code = event.keyCode
        let kind: KeyInput.Kind
        switch event.type {
        case .keyDown:
            kind = .down
            pressed.insert(code)
        case .keyUp:
            kind = .up
            pressed.remove(code)
        default:
            kind = .flagsChanged
            capsLock = event.modifierFlags.contains(.capsLock)
            if let flag = KeyClassifier.modifierFlag(forKeyCode: code), flag != .capsLock {
                if Self.modifiers(event.modifierFlags).contains(flag) { pressed.insert(code) } else { pressed.remove(code) }
            }
        }
        play(KeyInput(
            keyCode: code, kind: kind,
            isRepeat: event.type != .flagsChanged && event.isARepeat,
            modifiers: Self.modifiers(event.modifierFlags),
            timestamp: event.timestamp
        ))
        return event.modifierFlags.contains(.command)
    }

    /// A key clicked with the pointer. Modifiers and Caps Lock toggle the way
    /// pressing them would.
    func click(_ code: UInt16, down: Bool) {
        if down {
            guard !clicked.contains(code) else { return } // The drag goes on; the key is already down.
            clicked.insert(code)
        } else {
            guard clicked.remove(code) != nil else { return }
        }
        var modifiers = Self.modifiers(NSEvent.modifierFlags)
        if capsLock { modifiers.insert(.capsLock) }
        let now = ProcessInfo.processInfo.systemUptime
        if code == KeyClassifier.capsLockKeyCode {
            guard down else { return }
            capsLock.toggle()
            if capsLock { modifiers.insert(.capsLock) } else { modifiers.remove(.capsLock) }
            play(KeyInput(keyCode: code, kind: .flagsChanged, modifiers: modifiers, timestamp: now))
            return
        }
        if let flag = KeyClassifier.modifierFlag(forKeyCode: code) {
            if down { modifiers.insert(flag) } else { modifiers.remove(flag) }
            if down { pressed.insert(code) } else { pressed.remove(code) }
            play(KeyInput(keyCode: code, kind: .flagsChanged, modifiers: modifiers, timestamp: now))
            return
        }
        if down { pressed.insert(code) } else { pressed.remove(code) }
        play(KeyInput(keyCode: code, kind: down ? .down : .up, modifiers: modifiers, timestamp: now))
    }

    private func play(_ input: KeyInput) {
        previewer.type(interpreter.interpret(input))
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        KeyTap.modifiers(CGEventFlags(rawValue: UInt64(flags.rawValue)))
    }
}

/// One key on the on-screen keyboard: a macOS key code, a label, and a width
/// in key units.
struct KeyCap: Identifiable {
    var code: UInt16
    var label: String
    var width: CGFloat = 1
    var id: UInt16 { code }

    /// Stands in for the arrow cluster at the end of the bottom row.
    static let arrowCluster: UInt16 = 0xFFFF

    /// Symbols where the words don't fit the small keyboard.
    var shortLabel: String {
        switch code {
        case 51: "⌫"
        case 48: "⇥"
        case 57: "⇪"
        case 36: "↩"
        case 56, 60: "⇧"
        default: label
        }
    }

    var spokenLabel: String {
        switch code {
        case 49: "space"
        case 59: "control"
        case 58, 61: "option"
        case 55, 54: "command"
        case 123: "left arrow"
        case 124: "right arrow"
        case 125: "down arrow"
        case 126: "up arrow"
        default: label
        }
    }

    private static func keys(_ labels: String, _ codes: [UInt16]) -> [KeyCap] {
        zip(labels.map(String.init), codes).map { KeyCap(code: $1, label: $0) }
    }

    /// A US Mac layout. Every row is 14.5 units wide.
    static let rows: [[KeyCap]] = [
        keys("`1234567890-=", [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24])
            + [KeyCap(code: 51, label: "delete", width: 1.5)],
        [KeyCap(code: 48, label: "tab", width: 1.5)]
            + keys("QWERTYUIOP[]\\", [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]),
        [KeyCap(code: 57, label: "caps lock", width: 1.75)]
            + keys("ASDFGHJKL;'", [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39])
            + [KeyCap(code: 36, label: "return", width: 1.75)],
        [KeyCap(code: 56, label: "shift", width: 2.25)]
            + keys("ZXCVBNM,./", [6, 7, 8, 9, 11, 45, 46, 43, 47, 44])
            + [KeyCap(code: 60, label: "shift", width: 2.25)],
        [
            KeyCap(code: 63, label: "fn"), KeyCap(code: 59, label: "⌃"), KeyCap(code: 58, label: "⌥"),
            KeyCap(code: 55, label: "⌘", width: 1.25), KeyCap(code: 49, label: "", width: 5),
            KeyCap(code: 54, label: "⌘", width: 1.25), KeyCap(code: 61, label: "⌥"),
            KeyCap(code: arrowCluster, label: "", width: 3),
        ],
    ]
}
