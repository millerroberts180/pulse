/// Key groups that sound subtly different. Only the group is ever derived
/// from a key code; which key was typed is never kept.
public enum KeyGroup: String, Sendable, CaseIterable {
    case text, space, returnKey, delete, navigation, modifier
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)

    /// Modifiers that turn a key press into a shortcut chord.
    public static let chordModifiers: KeyModifiers = [.command, .control, .option]
}

public enum KeyClassifier {
    /// macOS virtual key codes (Carbon `kVK_*`).
    public static func group(forKeyCode code: UInt16) -> KeyGroup {
        switch code {
        case 49: .space
        case 36, 76: .returnKey // Return, keypad Enter
        case 51, 117: .delete // Backspace, forward Delete
        case 123, 124, 125, 126, // arrows
             115, 119, 116, 121, // Home, End, Page Up, Page Down
             48, 53, // Tab, Escape
             122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
             105, 107, 113, 106, 64, 79, 80, 90: // F13–F20
            .navigation
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63: .modifier
        default: .text
        }
    }

    /// The modifier flag a modifier key toggles, for press/release detection.
    public static func modifierFlag(forKeyCode code: UInt16) -> KeyModifiers? {
        switch code {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        case 57: .capsLock
        case 63: .function
        default: nil
        }
    }

    public static let capsLockKeyCode: UInt16 = 57
}

/// One raw keyboard event, reduced to what Pulse needs.
public struct KeyInput: Sendable {
    public enum Kind: Sendable { case down, up, flagsChanged }

    public var keyCode: UInt16
    public var kind: Kind
    public var isRepeat: Bool
    public var modifiers: KeyModifiers
    /// Seconds, any monotonic clock.
    public var timestamp: Double

    public init(keyCode: UInt16, kind: Kind, isRepeat: Bool = false, modifiers: KeyModifiers = [], timestamp: Double) {
        self.keyCode = keyCode
        self.kind = kind
        self.isRepeat = isRepeat
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// What happened, in the terms profiles voice.
public enum KeyMoment: Sendable, Equatable {
    case press(KeyGroup, chord: Bool)
    case release(KeyGroup)
    case heldRepeat(KeyGroup)
    case capsLock(on: Bool)
    case repeatWarning
}

/// Turns raw key events into moments. Holds only timing and modifier state.
public struct KeyInterpreter: Sendable {
    /// Held Delete warns after this many repeats; any other key after `repeatsBeforeWarning`.
    public var deleteRepeatsBeforeWarning = 3
    public var repeatsBeforeWarning = 8
    /// Warnings are rate limited so a held key doesn't become an alarm.
    public var warningInterval: Double = 0.8

    private var modifiers: KeyModifiers = []
    /// Modifier keys physically down, by key code, so releasing left Shift
    /// while right Shift is held reads as a release, not a second press.
    private var heldModifierKeys: Set<UInt16> = []
    private var repeatCount = 0
    private var lastWarning: Double = -.infinity

    /// `modifiers`: the keyboard's state right now, so Caps Lock and held
    /// modifiers are known from the first event.
    public init(modifiers: KeyModifiers = []) {
        self.modifiers = modifiers
    }

    public mutating func interpret(_ input: KeyInput) -> [KeyMoment] {
        // A key-up can be missed (Secure Event Input hides it, or the tap was
        // briefly disabled). A held key whose flag is absent is no longer down.
        if !heldModifierKeys.isEmpty {
            heldModifierKeys = heldModifierKeys.filter { code in
                KeyClassifier.modifierFlag(forKeyCode: code).map(input.modifiers.contains) ?? false
            }
        }
        switch input.kind {
        case .down where input.isRepeat:
            let group = KeyClassifier.group(forKeyCode: input.keyCode)
            repeatCount += 1
            var moments: [KeyMoment] = [.heldRepeat(group)]
            let threshold = group == .delete ? deleteRepeatsBeforeWarning : repeatsBeforeWarning
            if repeatCount >= threshold, input.timestamp - lastWarning >= warningInterval {
                lastWarning = input.timestamp
                moments.append(.repeatWarning)
            }
            return moments

        case .down:
            repeatCount = 0
            let group = KeyClassifier.group(forKeyCode: input.keyCode)
            let chord = group != .modifier && !input.modifiers.isDisjoint(with: .chordModifiers)
            return [.press(group, chord: chord)]

        case .up:
            let group = KeyClassifier.group(forKeyCode: input.keyCode)
            return group == .modifier ? [] : [.release(group)]

        case .flagsChanged:
            defer { modifiers = input.modifiers }
            if input.keyCode == KeyClassifier.capsLockKeyCode {
                let on = input.modifiers.contains(.capsLock)
                return on == modifiers.contains(.capsLock) ? [] : [.capsLock(on: on)]
            }
            guard let flag = KeyClassifier.modifierFlag(forKeyCode: input.keyCode) else { return [] }
            if !input.modifiers.contains(flag) {
                // The flag clearing is authoritative: no key with it is down.
                heldModifierKeys = heldModifierKeys.filter { KeyClassifier.modifierFlag(forKeyCode: $0) != flag }
                return [.release(.modifier)]
            }
            if heldModifierKeys.remove(input.keyCode) != nil {
                // This side came up while the other side still holds the flag.
                return [.release(.modifier)]
            }
            heldModifierKeys.insert(input.keyCode)
            return [.press(.modifier, chord: false)]
        }
    }
}

/// Keyboard sound profiles plus silence.
public enum KeyboardProfile: String, Sendable, CaseIterable, Codable {
    /// One quiet, consistent key-down sound. Designed to sit behind typing
    /// rather than describe each key.
    case ambient
    /// A real keyboard's sounds, from the chosen board: each key group its
    /// own, with optional up-strokes. (Stored as "creamy", its old name.)
    case mechanical = "creamy"
    /// Quiet, nonverbal confirmation and state cues for typing confidence.
    case keySense
    case quiet
}

/// KeySense's nonverbal cues.
public enum KeySenseVoice: String, Sendable, CaseIterable {
    case text, space, returnKey, delete, navigation, modifier
    case chord, capsLockOn, capsLockOff, repeatWarning

    init(_ group: KeyGroup) {
        self = switch group {
        case .text: .text
        case .space: .space
        case .returnKey: .returnKey
        case .delete: .delete
        case .navigation: .navigation
        case .modifier: .modifier
        }
    }
}

/// A sound in the bank.
public enum VoiceKey: Hashable, Sendable {
    case boardPress(KeyGroup)
    case boardRelease(KeyGroup)
    case keySense(KeySenseVoice)
    case page(Cue)
}

public struct VoiceRequest: Sendable, Equatable {
    public var key: VoiceKey
    public var gain: Float
}

/// Which sounds a moment makes under a profile.
public struct KeyboardVoicing: Sendable, Equatable {
    public var profile: KeyboardProfile
    public var releaseSounds: Bool
    public var repeatWarnings: Bool

    public init(profile: KeyboardProfile, releaseSounds: Bool = true, repeatWarnings: Bool = true) {
        self.profile = profile
        self.releaseSounds = releaseSounds
        self.repeatWarnings = repeatWarnings
    }

    public func voices(for moment: KeyMoment) -> [VoiceRequest] {
        switch (profile, moment) {
        case (.quiet, _):
            return []

        // Ambient is intentionally one unchanging, low-level texture. No
        // releases, state pips, or per-key categories compete with typing.
        case (.ambient, .press):
            return [VoiceRequest(key: .boardPress(.text), gain: 0.28)]
        case (.ambient, .release), (.ambient, .heldRepeat),
             (.ambient, .capsLock), (.ambient, .repeatWarning):
            return []

        case let (.mechanical, .press(group, _)):
            return [VoiceRequest(key: .boardPress(group), gain: 1)]
        case let (.mechanical, .release(group)):
            return releaseSounds ? [VoiceRequest(key: .boardRelease(group), gain: 1)] : []
        case let (.mechanical, .heldRepeat(group)):
            return [VoiceRequest(key: .boardPress(group), gain: 0.55)]
        case (.mechanical, .capsLock):
            return [VoiceRequest(key: .boardPress(.modifier), gain: 1)]

        case let (.keySense, .press(group, chord)):
            return [VoiceRequest(key: .keySense(chord ? .chord : KeySenseVoice(group)), gain: 1)]
        case (.keySense, .release), (.keySense, .heldRepeat):
            return []
        case let (.keySense, .capsLock(on)):
            return [VoiceRequest(key: .keySense(on ? .capsLockOn : .capsLockOff), gain: 1)]

        case (.mechanical, .repeatWarning), (.keySense, .repeatWarning):
            return repeatWarnings ? [VoiceRequest(key: .keySense(.repeatWarning), gain: 0.8)] : []
        }
    }

    /// The haptic equivalent of a state moment, so no important cue is audio-only.
    public static func hapticCue(for moment: KeyMoment) -> Cue? {
        switch moment {
        case let .capsLock(on): on ? .capsLockOn : .capsLockOff
        case .repeatWarning: .repeatWarning
        case .press(_, chord: true): .chord
        case .press, .release, .heldRepeat: nil
        }
    }
}
