import AppKit
import PulseCore
import QuartzCore
import os

/// Plays cues on the trackpad. The public haptic performer is deliberately the
/// primary path: private actuator calls can report success on newer macOS
/// versions without producing a perceptible pulse. The actuator remains
/// available for diagnostics and future, hardware-validated custom shapes.
///
/// Policy: one action, one cue. A cue arriving within the collision window of
/// a higher-priority cue is dropped; an equal or higher one replaces it.
/// Only the patterns the public API offers are used: three strengths, so cues
/// differ by strength and rhythm, never by more than two pulses.
final class HapticOutput {
    var strength: Float = 1
    var isMuted = false

    // The private actuator isn't opened here: nothing plays through it, so
    // loading MultitouchSupport at launch would be pure cost. `--diagnose`
    // opens it on demand.
    private var last: (cue: Cue, time: CFTimeInterval)?
    private var generation = 0

    static let collisionWindow: CFTimeInterval = 0.12
    /// Pulses closer than this blur into one.
    static let minimumGap: CFTimeInterval = 0.02

    /// Applies the one-cue policy and returns whether the cue won. It wins
    /// even while haptics are muted or `feel` is false, so a cue's sound can
    /// stand in for it (audio-only mode, momentum glides).
    @discardableResult
    func play(_ cue: Cue, feel: Bool = true, ignoringMute: Bool = false) -> Bool {
        let now = CACurrentMediaTime()
        if let last {
            let elapsed = now - last.time
            if elapsed < Self.minimumGap { return false }
            // A glide after a swell is the same motion going on, not a collision.
            let continuesMotion = last.cue == .swell && cue == .glide
            if elapsed < Self.collisionWindow, last.cue.priority > cue.priority, !continuesMotion { return false }
        }
        last = (cue, now)
        generation += 1
        if feel, ignoringMute || !isMuted {
            perform(cue.shape.publicPulses(strength: strength), generation: generation, ignoringMute: ignoringMute)
        }
        return true
    }

    /// A deliberately obvious cue for checking that the active trackpad can
    /// receive feedback: the strongest ripple. It bypasses mute, because mute
    /// must not prevent a user from diagnosing why ordinary page cues are absent.
    func playTest() {
        generation += 1
        perform([
            PublicPulse(offsetMs: 0, pattern: .levelChange),
            PublicPulse(offsetMs: 45, pattern: .generic),
            PublicPulse(offsetMs: 100, pattern: .alignment),
        ], generation: generation, ignoringMute: true)
    }

    /// Plays one cue as it feels in use, for the setup and Settings › Cues.
    /// Like the test, it ignores mute: previewing is how cues are learned.
    func preview(_ cue: Cue) {
        last = (cue, CACurrentMediaTime())
        generation += 1
        perform(cue.shape.publicPulses(strength: strength), generation: generation, ignoringMute: true)
    }

    private func perform(_ pulses: [PublicPulse], generation mine: Int, ignoringMute: Bool) {
        for pulse in pulses {
            guard pulse.offsetMs > 0 else {
                fire(pulse.pattern)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pulse.offsetMs / 1000) { [weak self] in
                MainActor.assumeIsolated {
                    // A newer cue supersedes the rest of this one.
                    guard let self, self.generation == mine, ignoringMute || !self.isMuted else { return }
                    self.fire(pulse.pattern)
                }
            }
        }
    }

    private func fire(_ pattern: PublicPattern) {
        let feedback: NSHapticFeedbackManager.FeedbackPattern = switch pattern {
        case .alignment: .alignment
        case .generic: .generic
        case .levelChange: .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(feedback, performanceTime: .now)
    }
}

/// The trackpad actuator through MultitouchSupport, a private framework,
/// resolved at runtime with dlopen/dlsym. If any piece is missing (or a macOS
/// update changes it), `make()` returns nil and Pulse uses the public API
/// instead.
///
/// Custom Gaussian pulses come from `MTActuationCreateFromDictionary`; each
/// distinct (amplitude, duration) pair is created once and reused. Where that
/// isn't available, the built-in actuation IDs 3–6 (weak to strong) stand in.
final class ActuatorDriver {
    private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuator = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenActuator = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias Actuate = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    private typealias CreateActuation = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    private typealias PlayActuation = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

    private struct PulseKey: Hashable {
        var amplitude: Int // tenths
        var duration: Int // tenths of a millisecond
    }

    private let listDevices: DeviceList?
    private let deviceID: DeviceID?
    private let createActuator: CreateActuator
    private let openActuator: OpenActuator
    private let actuate: Actuate
    private let createActuation: CreateActuation?
    private let playActuation: PlayActuation?

    /// Opened actuators by device ID. Never closed while Pulse runs.
    private var actuators: [UInt64: UnsafeMutableRawPointer] = [:]
    private var actuations: [PulseKey: UnsafeMutableRawPointer] = [:]
    private var lastRefresh: CFTimeInterval = 0
    private let log = Logger(subsystem: "com.millerroberts.Pulse", category: "haptics")

    /// Actuator ID used by older Intel MacBooks, tried when enumeration fails.
    private static let legacyDeviceID: UInt64 = 0x2_0000_0001

    static func make() -> ActuatorDriver? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let create = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let open = dlsym(handle, "MTActuatorOpen"),
              let actuate = dlsym(handle, "MTActuatorActuate")
        else { return nil }
        let driver = ActuatorDriver(
            listDevices: dlsym(handle, "MTDeviceCreateList").map { unsafeBitCast($0, to: DeviceList.self) },
            deviceID: dlsym(handle, "MTDeviceGetDeviceID").map { unsafeBitCast($0, to: DeviceID.self) },
            createActuator: unsafeBitCast(create, to: CreateActuator.self),
            openActuator: unsafeBitCast(open, to: OpenActuator.self),
            actuate: unsafeBitCast(actuate, to: Actuate.self),
            createActuation: dlsym(handle, "MTActuationCreateFromDictionary").map { unsafeBitCast($0, to: CreateActuation.self) },
            playActuation: dlsym(handle, "MTActuationActuate").map { unsafeBitCast($0, to: PlayActuation.self) }
        )
        driver.refreshDevices()
        return driver.actuators.isEmpty ? nil : driver
    }

    private init(
        listDevices: DeviceList?, deviceID: DeviceID?, createActuator: CreateActuator,
        openActuator: OpenActuator, actuate: Actuate,
        createActuation: CreateActuation?, playActuation: PlayActuation?
    ) {
        self.listDevices = listDevices
        self.deviceID = deviceID
        self.createActuator = createActuator
        self.openActuator = openActuator
        self.actuate = actuate
        self.createActuation = createActuation
        self.playActuation = playActuation
    }

    /// Opens an actuator for every haptic trackpad not yet known. Mice and
    /// other multitouch devices without a motor fail to open and are skipped.
    func refreshDevices() {
        lastRefresh = CACurrentMediaTime()
        var ids: [UInt64] = []
        if let listDevices, let deviceID, let devices = listDevices()?.takeRetainedValue() as? [AnyObject] {
            for device in devices {
                var id: UInt64 = 0
                if deviceID(Unmanaged.passUnretained(device).toOpaque(), &id) == 0, id != 0 { ids.append(id) }
            }
        }
        if ids.isEmpty, actuators.isEmpty { ids = [Self.legacyDeviceID] }
        for id in ids where actuators[id] == nil {
            guard let actuator = createActuator(id) else { continue }
            if openActuator(actuator) == 0 {
                actuators[id] = actuator
            } else {
                Unmanaged<AnyObject>.fromOpaque(actuator).release()
            }
        }
    }

    /// Whether Gaussian pulses can be built (creates one without playing it).
    var supportsCustomPulses: Bool {
        playActuation != nil && actuation(amplitude: 1, durationMs: 2) != nil
    }

    /// Plays one pulse on every trackpad. Returns false if nothing accepted it.
    func play(amplitude: Float, durationMs: Float) -> Bool {
        var played = false
        if let actuation = actuation(amplitude: amplitude, durationMs: durationMs), let playActuation {
            for actuator in actuators.values where playActuation(actuation, actuator, 0, 1, 0) == 0 {
                played = true
            }
        } else {
            let id = Self.builtInID(for: amplitude)
            for actuator in actuators.values where actuate(actuator, id, 0, 0, 0) == 0 {
                played = true
            }
        }
        // A trackpad reconnected or the Mac woke: re-open, at most every 5 s.
        if !played, CACurrentMediaTime() - lastRefresh > 5 { refreshDevices() }
        return played
    }

    private func actuation(amplitude: Float, durationMs: Float) -> UnsafeMutableRawPointer? {
        guard let createActuation else { return nil }
        let key = PulseKey(amplitude: Int((amplitude * 10).rounded()), duration: Int((durationMs * 10).rounded()))
        if let cached = actuations[key] { return cached }
        let waveform: [String: Any] = [
            "BaseWaveform": [
                "Type": "Gaussian",
                "Amplitude": Float(key.amplitude) / 10,
                "DurationMS": Float(key.duration) / 10,
            ] as [String: Any],
        ]
        guard let actuation = createActuation(waveform as CFDictionary, 0) else {
            log.error("Custom actuation unavailable; using built-in patterns")
            return nil
        }
        actuations[key] = actuation
        return actuation
    }

    /// The built-in strength ladder: 3 (weak) through 6 (strong).
    private static func builtInID(for amplitude: Float) -> Int32 {
        switch amplitude {
        case ..<1.8: 3
        case ..<2.8: 4
        case ..<3.4: 5
        default: 6
        }
    }
}
