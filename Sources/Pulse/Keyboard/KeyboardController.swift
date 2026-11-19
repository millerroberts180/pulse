import AppKit
import PulseCore
import os

/// Owns keyboard sound: capture, quiet rules, and the profile in effect.
///
/// Keys are only observed while they could make a sound or a state haptic.
/// With keyboard sound off, Pulse muted, or the Quiet profile without
/// keyboard haptics, there is no key tap and no Core Audio listener at all.
final class KeyboardController {
    enum Status: Equatable {
        case off, disabled, playing, hapticsOnly, mutedByUser, excludedApp, microphoneInUse, mediaPlaying, voiceOverDefault, unavailable
    }

    private(set) var status: Status = .off
    var onStatusChange: (() -> Void)?

    private let audio: CueAudio
    private let engine: KeyboardEngine
    private lazy var tap = KeyTap { [engine] input in engine.handle(input) }
    private let quiet = QuietMonitor()
    private var fallbackMonitors: [Any] = []
    private var settings = PulseSettings()
    private var frontmostExcluded = false
    /// Another app is playing audio (see `MediaMonitor`).
    private var mediaPlaying = false
    /// The on-screen keyboard in Settings › Keyboard, in front and voicing
    /// keys itself.
    private var demos: Set<String> = []
    private var demoActive: Bool { !demos.isEmpty }
    /// Accessibility is granted and detectors may run.
    private var allowed = false
    private var capturing = false
    private var captureFailed = false
    private let log = Logger(subsystem: "com.millerroberts.Pulse", category: "keyboard")

    init(audio: CueAudio, haptics: HapticOutput) {
        self.audio = audio
        engine = KeyboardEngine(audio: audio) { cue in
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = haptics.play(cue) } }
        }
        quiet.onChange = { [weak self] in self?.refresh() }
    }

    func start() {
        allowed = true
        refresh()
    }

    func stop() {
        allowed = false
        refresh()
    }

    func apply(_ settings: PulseSettings, frontmostExcluded: Bool, mediaPlaying: Bool) {
        self.settings = settings
        self.frontmostExcluded = frontmostExcluded
        self.mediaPlaying = mediaPlaying
        refresh()
    }

    func setDemo(_ source: String, active: Bool) {
        let wasActive = demoActive
        if active { demos.insert(source) } else { demos.remove(source) }
        if demoActive != wasActive { refresh() }
    }

    private func refresh() {
        let stateHaptics = settings.keyboardHaptics && settings.hapticsEnabled
        // Persistent "off" states stop capture. Transient silences (excluded
        // app, microphone, VoiceOver) keep it, so modifier state stays true.
        setCapturing(allowed && settings.keyboardEnabled && !settings.muted
            && (settings.keyboardProfile != .quiet || stateHaptics))

        let newStatus: Status
        if !allowed {
            newStatus = .off
        } else if !settings.keyboardEnabled {
            newStatus = .disabled
        } else if settings.muted {
            newStatus = .mutedByUser
        } else if captureFailed {
            newStatus = .unavailable
        } else if frontmostExcluded {
            newStatus = .excludedApp
        } else if settings.quietWhileMicrophoneInUse, quiet.microphoneInUse {
            newStatus = .microphoneInUse
        } else if settings.quietWhileMediaPlays, mediaPlaying {
            newStatus = .mediaPlaying
        } else if quiet.voiceOverRunning, !settings.keyboardProfileChosen {
            // Complement VoiceOver rather than compete with it.
            newStatus = .voiceOverDefault
        } else {
            newStatus = settings.keyboardProfile != .quiet ? .playing : (stateHaptics ? .hapticsOnly : .off)
        }

        engine.update(KeyboardEngine.Config(
            voicing: KeyboardVoicing(
                profile: settings.keyboardProfile,
                releaseSounds: settings.keyReleaseSounds,
                repeatWarnings: settings.repeatWarnings
            ),
            volume: settings.keyboardVolume,
            silenced: newStatus != .playing || demoActive,
            stateHaptics: stateHaptics && capturing && !frontmostExcluded && !demoActive
        ))
        audio.setBoard(settings.keyboardBoard)
        // Render sounds and build the audio graph only once they can play.
        if newStatus == .playing { audio.prepareIfNeeded() }
        if newStatus != status {
            status = newStatus
            onStatusChange?()
        }
    }

    private func setCapturing(_ on: Bool) {
        guard on != capturing else { return }
        capturing = on
        captureFailed = false
        if on {
            engine.reset() // Nothing is delivering events yet.
            quiet.start()
            if !tap.start() {
                // The tap needs Accessibility; NSEvent monitors are the fallback
                // (delivered on the main thread, slightly later).
                log.notice("Key event tap unavailable; using event monitors")
                let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
                if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [engine] event in
                    engine.handle(Self.input(event))
                }) {
                    fallbackMonitors.append(monitor)
                } else {
                    captureFailed = true
                }
            }
        } else {
            tap.stop()
            fallbackMonitors.forEach(NSEvent.removeMonitor)
            fallbackMonitors = []
            quiet.stop()
        }
    }

    private static func input(_ event: NSEvent) -> KeyInput {
        let kind: KeyInput.Kind = switch event.type {
        case .keyDown: .down
        case .keyUp: .up
        default: .flagsChanged
        }
        let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        return KeyInput(
            keyCode: event.keyCode,
            kind: kind,
            isRepeat: (event.type == .keyDown || event.type == .keyUp) && event.isARepeat,
            modifiers: KeyTap.modifiers(cgFlags),
            timestamp: event.timestamp
        )
    }
}
