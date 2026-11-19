import AppKit
import PulseCore
import os

/// Observes key events system-wide on a dedicated high-priority thread, so a
/// busy main thread never delays a keystroke's sound. Listen-only: events are
/// never modified. Only the key code's group and modifier state are used;
/// characters are never read, stored, or sent.
///
/// Password fields enable Secure Event Input, which withholds key events from
/// every observer, so Pulse is automatically silent there.
nonisolated final class KeyTap: @unchecked Sendable {
    private let handler: @Sendable (KeyInput) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(handler: @escaping @Sendable (KeyInput) -> Void) {
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    /// Returns false when the system refuses the tap (no permission).
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap

        let ready = DispatchSemaphore(value: 0)
        // Handed to the tap thread, which alone uses them from here on.
        nonisolated(unsafe) let handoff = (tap: tap, source: source)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), handoff.source, .commonModes)
            CGEvent.tapEnable(tap: handoff.tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Pulse key tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            handler(Self.input(type, event))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    static func input(_ type: CGEventType, _ event: CGEvent) -> KeyInput {
        let kind: KeyInput.Kind = switch type {
        case .keyDown: .down
        case .keyUp: .up
        default: .flagsChanged
        }
        return KeyInput(
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            kind: kind,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            modifiers: modifiers(event.flags),
            timestamp: Double(event.timestamp) / 1_000_000_000
        )
    }

    static func modifiers(_ flags: CGEventFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlphaShift) { modifiers.insert(.capsLock) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }
}

/// Runs on the tap's own thread.
private nonisolated func keyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// Turns key events into sounds (and optional haptic equivalents) on whatever
/// thread delivers them. Its interpreter is only ever touched by that one
/// thread; settings arrive as a locked snapshot.
nonisolated final class KeyboardEngine: @unchecked Sendable {
    struct Config: Sendable {
        var voicing = KeyboardVoicing(profile: .quiet)
        var volume: Float = 0.6
        /// No sound: Quiet profile, excluded app, microphone in use, or the
        /// VoiceOver default. State haptics are governed separately.
        var silenced = false
        var stateHaptics = false
    }

    private let config = OSAllocatedUnfairLock(initialState: Config())
    private var interpreter = KeyInterpreter()
    private let audio: CueAudio
    private let onHaptic: @Sendable (Cue) -> Void

    init(audio: CueAudio, onHaptic: @escaping @Sendable (Cue) -> Void) {
        self.audio = audio
        self.onHaptic = onHaptic
    }

    func update(_ newConfig: Config) {
        config.withLock { $0 = newConfig }
    }

    /// Starts over from the keyboard's state right now. Only while no events
    /// are being delivered (capture stopped), so the interpreter's thread
    /// isn't running: keys released while Pulse wasn't listening must not
    /// read as held, and Caps Lock must match the light.
    func reset() {
        interpreter = KeyInterpreter(modifiers: KeyTap.modifiers(CGEventSource.flagsState(.combinedSessionState)))
    }

    func handle(_ input: KeyInput) {
        // Interpret even while silent, so modifier and Caps Lock state stay true.
        let moments = interpreter.interpret(input)
        let config = config.withLock { $0 }
        guard !moments.isEmpty, !config.silenced || config.stateHaptics else { return }
        for moment in moments {
            if !config.silenced {
                for request in config.voicing.voices(for: moment) {
                    audio.play(request.key, gain: request.gain * config.volume)
                }
            }
            if config.stateHaptics, let cue = KeyboardVoicing.hapticCue(for: moment) {
                onHaptic(cue)
            }
        }
    }
}
