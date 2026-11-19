/// Pulse's physical vocabulary. Every moment maps to exactly one cue, and the
/// set stays small so the feel of each one can be learned.
public enum Cue: String, CaseIterable, Sendable {
    /// Hover or keyboard focus lands on a lightweight navigation target: a
    /// link or generic pressable control.
    case actionable
    /// Hover or keyboard focus lands on a control that changes state or takes
    /// an immediate action: button, switch, tab, or menu item.
    case action
    /// The selected item in a sidebar, list, or tab strip changed.
    case navigation
    /// A heading crosses the reading line while scrolling.
    case landmark
    /// A destructive control, an invalid field, or an alert.
    case caution
    /// Scrolling reached the start or end of a scrollable region.
    case boundary
    /// A user-enabled waypoint: a find-in-page match, or highlighted text
    /// crossing the reading line.
    case waypoint
    /// Motion scrolling: one soft pulse of a sustained fast scroll.
    case glide
    /// Motion scrolling: a quick burst of acceleration.
    case swell
    /// Keyboard state cues: haptic equivalents of KeySense sounds.
    case capsLockOn, capsLockOff, chord, repeatWarning

    /// When two cues collide, the higher priority one plays and the other is
    /// dropped ("one action, one cue").
    public var priority: Int {
        switch self {
        case .caution: 5
        case .boundary, .capsLockOn, .capsLockOff, .repeatWarning: 4
        case .landmark, .waypoint: 3
        case .action, .navigation, .chord: 2
        case .actionable, .swell: 1
        case .glide: 0
        }
    }

    /// The default feel. Amplitudes are MultitouchSupport Gaussian units,
    /// which Pulse keeps between 0.1 and 4 (`HapticShape`). Longer pulses
    /// read as softer and lower, shorter ones as crisper. All of these are
    /// starting points to tune on real hardware.
    public var shape: HapticShape {
        switch self {
        // One action, one pulse. Several public patterns in quick succession
        // read as a double or triple click, never as a ripple, so hover and
        // selection cues are single pulses told apart by strength.
        case .actionable:
            HapticShape([.init(amplitude: 1.4, durationMs: 2.0, fallback: .light)])
        case .action:
            // Firmer than a link's: this control does something.
            HapticShape([.init(amplitude: 2.2, durationMs: 2.8, fallback: .medium)])
        case .navigation:
            HapticShape([.init(amplitude: 1.8, durationMs: 2.0, fallback: .light)])
        case .landmark:
            HapticShape([.init(amplitude: 3.0, durationMs: 6.0, fallback: .medium)])
        case .caution:
            // The one deliberate double: high consequence must not feel ordinary.
            HapticShape([
                .init(amplitude: 3.4, durationMs: 3.8, fallback: .strong),
                .init(amplitude: 3.4, durationMs: 3.8, offsetMs: 95, fallback: .strong),
            ])
        case .boundary:
            // A landing with a small settle, so it can't be mistaken for a landmark.
            HapticShape([
                .init(amplitude: 3.2, durationMs: 6.0, fallback: .medium),
                .init(amplitude: 1.2, durationMs: 6.0, offsetMs: 70, fallback: .faint),
            ])
        case .waypoint:
            // Rising, and slower than a caution: "found it", not "careful".
            HapticShape([
                .init(amplitude: 1.4, durationMs: 2.0, fallback: .light),
                .init(amplitude: 2.6, durationMs: 3.0, offsetMs: 110, fallback: .medium),
            ])
        case .glide:
            HapticShape([.init(amplitude: 0.8, durationMs: 2.0, fallback: .faint)])
        case .swell:
            HapticShape([.init(amplitude: 1.8, durationMs: 6.0, fallback: .light)])
        case .capsLockOn:
            HapticShape([
                .init(amplitude: 1.2, durationMs: 2.0, fallback: .light),
                .init(amplitude: 3.0, durationMs: 3.8, offsetMs: 70, fallback: .medium),
            ])
        case .capsLockOff:
            HapticShape([
                .init(amplitude: 3.0, durationMs: 3.8, fallback: .medium),
                .init(amplitude: 1.2, durationMs: 2.0, offsetMs: 70, fallback: .light),
            ])
        case .chord:
            HapticShape([.init(amplitude: 2.0, durationMs: 2.0, fallback: .light)])
        case .repeatWarning:
            HapticShape([
                .init(amplitude: 2.6, durationMs: 2.0, fallback: .medium),
                .init(amplitude: 2.6, durationMs: 2.0, offsetMs: 60, fallback: .medium),
            ])
        }
    }
}

/// How strong a pulse is meant to feel, before the user's strength setting.
public enum SystemPattern: Sendable, Hashable {
    case light, medium, strong
    /// An echo: always the lightest pattern, and only played when it is
    /// lighter than the cue's first pulse, so a ripple can never collapse
    /// into two equal taps.
    case faint
}

/// The public haptic API's three patterns, weakest to strongest. macOS
/// exposes no other amplitude control.
public enum PublicPattern: Int, Sendable, Comparable {
    case alignment, generic, levelChange

    public static func < (lhs: PublicPattern, rhs: PublicPattern) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One pulse as the public API will play it.
public struct PublicPulse: Sendable, Equatable {
    public var offsetMs: Double
    public var pattern: PublicPattern

    public init(offsetMs: Double, pattern: PublicPattern) {
        self.offsetMs = offsetMs
        self.pattern = pattern
    }
}

/// One Gaussian pulse of the trackpad actuator.
public struct HapticPulse: Sendable, Hashable {
    public var amplitude: Float
    public var durationMs: Float
    /// Delay from the start of the cue.
    public var offsetMs: Double
    /// What to play instead through the public API.
    public var fallback: SystemPattern

    public init(amplitude: Float, durationMs: Float, offsetMs: Double = 0, fallback: SystemPattern) {
        self.amplitude = amplitude
        self.durationMs = durationMs
        self.offsetMs = offsetMs
        self.fallback = fallback
    }
}

public struct HapticShape: Sendable, Hashable {
    /// The highest and lowest amplitudes Pulse ever sends.
    public static let maximumAmplitude: Float = 4.0
    public static let minimumAmplitude: Float = 0.1

    public var pulses: [HapticPulse]

    public init(_ pulses: [HapticPulse]) {
        self.pulses = pulses
    }

    /// The pulses the public haptic API plays at a user strength. Firm and
    /// Strong (≥ 1.25) step light and medium pulses up one pattern; echoes
    /// that wouldn't be lighter than the first pulse are dropped.
    public func publicPulses(strength: Float) -> [PublicPulse] {
        let firm = strength >= 1.25
        var result: [PublicPulse] = []
        for pulse in pulses {
            let pattern: PublicPattern = switch pulse.fallback {
            case .faint: .alignment
            case .light: firm ? .generic : .alignment
            case .medium: firm ? .levelChange : .generic
            case .strong: .levelChange
            }
            if pulse.fallback == .faint, let first = result.first, !(pattern < first.pattern) { continue }
            result.append(PublicPulse(offsetMs: pulse.offsetMs, pattern: pattern))
        }
        return result
    }

    /// The shape at a user strength (1 = default), clamped to safe amplitudes
    /// and quantized to 0.1 so a handful of actuations can be cached.
    public func scaled(by strength: Float) -> HapticShape {
        HapticShape(pulses.map { pulse in
            var scaled = pulse
            let raw = min(max(pulse.amplitude * strength, Self.minimumAmplitude), Self.maximumAmplitude)
            scaled.amplitude = (raw * 10).rounded() / 10
            return scaled
        })
    }
}
