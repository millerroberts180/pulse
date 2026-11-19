import Combine
import Foundation
import PulseCore

/// Everything Pulse remembers. Preferences only: never page text, URLs,
/// accessibility labels, or keystrokes.
struct PulseSettings: Codable, Equatable {
    var muted = false

    // Page cues
    var hapticsEnabled = true
    var linkCues = true
    var controlCues = true
    var headingCues = true
    var navigationCues = true
    var cautionCues = true
    var boundaryCues = true
    /// Find-in-page matches and highlighted text. Opt-in: only some browsers
    /// report them.
    var waypointCues = false
    var hapticStrength: Float = 1.3
    /// Page cues are heard as well as felt. With haptics off this is
    /// audio-only mode, and links and controls get tones of their own.
    var pageSounds = false
    /// A trackpad click is felt once, as it goes down: the firmware's release
    /// click is silenced while Pulse runs (see `ReleaseClick`).
    var silenceReleaseClick = true

    // Motion scrolling
    var glideCues = true
    var swellCues = true
    var motionHaptics = true
    var motionSounds = false
    var motionThreshold: MotionThreshold = .standard
    var motionIntensity: MotionIntensity = .standard
    /// Level of page and motion sounds (keyboard sound has its own).
    var cueVolume: Float = 0.5

    // Keyboard
    var keyboardEnabled = true
    var keyboardProfile: KeyboardProfile = .ambient
    /// The keyboard Mechanical and Ambient sound like: the Red board by default.
    var keyboardBoard: KeyboardBoard = .red
    /// Whether the user picked a profile themselves (VoiceOver users keep
    /// Pulse quiet until they do).
    var keyboardProfileChosen = false
    var keyReleaseSounds = false
    var repeatWarnings = false
    var keyboardHaptics = false
    var keyboardVolume: Float = 0.35
    var quietWhileMicrophoneInUse = true
    /// Pulse's sounds step aside while another app plays audio.
    var quietWhileMediaPlays = true

    /// Bundle identifiers where Pulse stays silent.
    var excludedApps: Set<String> = []

    /// Page cues run while they can be felt or heard.
    var pageFeedback: Bool { hapticsEnabled || pageSounds }
    var motionFeedback: Bool { (glideCues || swellCues) && ((hapticsEnabled && motionHaptics) || motionSounds) }

    /// Whether a cue is in use, for the cue picker. Keyboard state cues
    /// follow the keyboard haptics switch.
    func isOn(_ cue: Cue) -> Bool {
        switch cue {
        case .actionable: linkCues
        case .action: controlCues
        case .caution: cautionCues
        case .navigation: navigationCues
        case .landmark: headingCues
        case .boundary: boundaryCues
        case .waypoint: waypointCues
        case .glide: glideCues
        case .swell: swellCues
        case .capsLockOn, .capsLockOff, .chord, .repeatWarning: keyboardHaptics
        }
    }

    mutating func set(_ cue: Cue, on: Bool) {
        switch cue {
        case .actionable: linkCues = on
        case .action: controlCues = on
        case .caution: cautionCues = on
        case .navigation: navigationCues = on
        case .landmark: headingCues = on
        case .boundary: boundaryCues = on
        case .waypoint: waypointCues = on
        case .glide: glideCues = on
        case .swell: swellCues = on
        case .capsLockOn, .capsLockOff, .chord, .repeatWarning: keyboardHaptics = on
        }
    }

    var pageOptions: PageDetector.Options {
        let page = pageFeedback
        return PageDetector.Options(
            links: page && linkCues,
            controls: page && controlCues,
            headings: page && headingCues,
            navigation: page && navigationCues,
            cautions: page && cautionCues,
            boundaries: page && boundaryCues,
            waypoints: page && waypointCues,
            motion: motionFeedback,
            glide: glideCues,
            swell: swellCues,
            motionHaptics: hapticsEnabled && motionHaptics,
            motionTuning: MotionModel.Tuning(threshold: motionThreshold, intensity: motionIntensity)
        )
    }

    /// Whether any of Pulse's sounds could play right now.
    var anySound: Bool {
        !muted && (pageSounds || motionSounds || (keyboardEnabled && keyboardProfile != .quiet))
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case muted, hapticsEnabled, linkCues, controlCues, headingCues, navigationCues,
             cautionCues, boundaryCues, waypointCues, hapticStrength, pageSounds, silenceReleaseClick,
             glideCues, swellCues, motionHaptics, motionSounds, motionThreshold, motionIntensity, cueVolume,
             keyboardEnabled, keyboardProfile, keyboardBoard, keyboardProfileChosen,
             keyReleaseSounds, repeatWarnings, keyboardHaptics, keyboardVolume,
             quietWhileMicrophoneInUse, quietWhileMediaPlays, excludedApps
    }

    /// Preferences predate individual on/off switches. Decode each field
    /// independently so an app update never discards a person's settings.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? muted
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? hapticsEnabled
        controlCues = try c.decodeIfPresent(Bool.self, forKey: .controlCues) ?? controlCues
        // Links shared the controls switch before they had their own.
        linkCues = try c.decodeIfPresent(Bool.self, forKey: .linkCues) ?? controlCues
        headingCues = try c.decodeIfPresent(Bool.self, forKey: .headingCues) ?? headingCues
        navigationCues = try c.decodeIfPresent(Bool.self, forKey: .navigationCues) ?? navigationCues
        cautionCues = try c.decodeIfPresent(Bool.self, forKey: .cautionCues) ?? cautionCues
        boundaryCues = try c.decodeIfPresent(Bool.self, forKey: .boundaryCues) ?? boundaryCues
        waypointCues = try c.decodeIfPresent(Bool.self, forKey: .waypointCues) ?? waypointCues
        hapticStrength = try c.decodeIfPresent(Float.self, forKey: .hapticStrength) ?? hapticStrength
        pageSounds = try c.decodeIfPresent(Bool.self, forKey: .pageSounds) ?? pageSounds
        silenceReleaseClick = try c.decodeIfPresent(Bool.self, forKey: .silenceReleaseClick) ?? silenceReleaseClick
        glideCues = try c.decodeIfPresent(Bool.self, forKey: .glideCues) ?? glideCues
        swellCues = try c.decodeIfPresent(Bool.self, forKey: .swellCues) ?? swellCues
        motionHaptics = try c.decodeIfPresent(Bool.self, forKey: .motionHaptics) ?? motionHaptics
        motionSounds = try c.decodeIfPresent(Bool.self, forKey: .motionSounds) ?? motionSounds
        // Unknown values (from a newer Pulse) fall back rather than fail.
        motionThreshold = (try? c.decodeIfPresent(MotionThreshold.self, forKey: .motionThreshold)) ?? motionThreshold
        motionIntensity = (try? c.decodeIfPresent(MotionIntensity.self, forKey: .motionIntensity)) ?? motionIntensity
        cueVolume = try c.decodeIfPresent(Float.self, forKey: .cueVolume) ?? cueVolume
        keyboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .keyboardEnabled) ?? keyboardEnabled
        keyboardProfile = (try? c.decodeIfPresent(KeyboardProfile.self, forKey: .keyboardProfile)) ?? keyboardProfile
        // So does a board an earlier Pulse had and this one doesn't.
        keyboardBoard = (try? c.decodeIfPresent(KeyboardBoard.self, forKey: .keyboardBoard)) ?? keyboardBoard
        keyboardProfileChosen = try c.decodeIfPresent(Bool.self, forKey: .keyboardProfileChosen) ?? keyboardProfileChosen
        keyReleaseSounds = try c.decodeIfPresent(Bool.self, forKey: .keyReleaseSounds) ?? keyReleaseSounds
        repeatWarnings = try c.decodeIfPresent(Bool.self, forKey: .repeatWarnings) ?? repeatWarnings
        keyboardHaptics = try c.decodeIfPresent(Bool.self, forKey: .keyboardHaptics) ?? keyboardHaptics
        keyboardVolume = try c.decodeIfPresent(Float.self, forKey: .keyboardVolume) ?? keyboardVolume
        quietWhileMicrophoneInUse = try c.decodeIfPresent(Bool.self, forKey: .quietWhileMicrophoneInUse) ?? quietWhileMicrophoneInUse
        quietWhileMediaPlays = try c.decodeIfPresent(Bool.self, forKey: .quietWhileMediaPlays) ?? quietWhileMediaPlays
        excludedApps = try c.decodeIfPresent(Set<String>.self, forKey: .excludedApps) ?? excludedApps
    }
}

/// Observable for the settings and setup windows; everything else is told
/// through `onChange`.
final class SettingsStore: ObservableObject {
    var onChange: (() -> Void)?

    var value: PulseSettings {
        willSet { objectWillChange.send() }
        didSet {
            guard value != oldValue else { return }
            scheduleSave()
            onChange?()
        }
    }

    private static let key = "settings.v1"
    private let defaults: UserDefaults
    private var pendingSave: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           var stored = try? JSONDecoder().decode(PulseSettings.self, from: data) {
            // The prior default was lively Mechanical with releases and a medium
            // level. Preserve an explicitly selected profile, but move an
            // untouched default to the calmer baseline.
            if !stored.keyboardProfileChosen, stored.keyboardProfile == .mechanical {
                stored.keyboardProfile = .ambient
                stored.keyReleaseSounds = false
                stored.repeatWarnings = false
                stored.keyboardVolume = min(stored.keyboardVolume, 0.35)
            }
            value = stored
        } else {
            value = PulseSettings()
        }
    }

    /// A dragged slider changes settings dozens of times a second; write
    /// once it settles.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes any pending change now (also called at quit).
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
