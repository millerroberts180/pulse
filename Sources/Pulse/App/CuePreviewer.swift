import AppKit
import PulseCore

/// Plays cues on request, for Settings and the setup's tour page. Previews ignore mute and the per-cue switches: feeling a cue is
/// how it is learned, and muting Pulse must not stop someone learning it.
final class CuePreviewer {
    private let haptics: HapticOutput
    private let audio: CueAudio
    private let store: SettingsStore
    private var generation = 0
    #if DEBUG
    /// The self-test takes the voices a demo key asks for instead of playing them.
    var typedForTesting: (([VoiceRequest]) -> Void)?
    #endif

    init(haptics: HapticOutput, audio: CueAudio, store: SettingsStore) {
        self.haptics = haptics
        self.audio = audio
        self.store = store
    }

    /// The cue as it is felt in use, plus its sound if that sound is on.
    func play(_ cue: Cue) {
        generation += 1
        switch cue {
        case .glide: playGlide(generation)
        default:
            haptics.preview(cue)
            if soundIsOn(for: cue) { sound(cue) }
        }
    }

    /// One pulse of the cue, even a glide.
    func feel(_ cue: Cue) {
        generation += 1
        haptics.preview(cue)
        if soundIsOn(for: cue) { sound(cue) }
    }

    /// Only the cue's sound, at the cue volume (even if page sounds are off).
    func hear(_ cue: Cue) {
        generation += 1
        if cue == .glide {
            playGlide(generation, feel: false, hear: true)
        } else {
            sound(cue)
        }
    }

    /// A cue from the tour page: the live policy decides (one action, one
    /// cue), but mute and the cue switches don't. Returns whether it played.
    func practice(_ cue: Cue, feel: Bool, level: Float) -> Bool {
        guard haptics.play(cue, feel: feel, ignoringMute: true) else { return false }
        if soundIsOn(for: cue) { sound(cue, level: level) }
        return true
    }

    /// Keys from the on-screen keyboard in Settings › Keyboard, voiced with
    /// the chosen profile and switches, exactly as live typing would be.
    func type(_ moments: [KeyMoment]) {
        let settings = store.value
        let profile = settings.keyboardEnabled ? settings.keyboardProfile : .quiet
        let voicing = KeyboardVoicing(profile: profile, releaseSounds: settings.keyReleaseSounds, repeatWarnings: settings.repeatWarnings)
        let gain = max(settings.keyboardVolume, 0.2)
        #if DEBUG
        if let hook = typedForTesting {
            hook(moments.flatMap(voicing.voices))
            return
        }
        #endif
        audio.prepareIfNeeded()
        for moment in moments {
            for request in voicing.voices(for: moment) { audio.play(request.key, gain: request.gain * gain) }
            if settings.keyboardHaptics, let cue = KeyboardVoicing.hapticCue(for: moment) { haptics.preview(cue) }
        }
    }

    /// A short phrase typed with a keyboard profile.
    func audition(_ profile: KeyboardProfile) {
        generation += 1
        let mine = generation
        let voicing = KeyboardVoicing(profile: profile, releaseSounds: store.value.keyReleaseSounds, repeatWarnings: true)
        // "Hello world", Return, then a shortcut.
        var moments: [KeyMoment] = [.press(.modifier, chord: false)]
        moments += Array(repeating: KeyMoment.press(.text, chord: false), count: 5)
        moments += [.press(.space, chord: false)] + Array(repeating: KeyMoment.press(.text, chord: false), count: 5)
        moments += [.press(.delete, chord: false), .press(.returnKey, chord: false), .press(.text, chord: true)]
        audio.prepareIfNeeded()
        let gain = max(store.value.keyboardVolume, 0.25)
        var time = 0.0
        for (index, moment) in moments.enumerated() {
            // An unhurried typist: 120–150 ms between keys.
            time += index == 0 ? 0 : 0.12 + 0.03 * Double((index * 7) % 5) / 4
            let requests = voicing.voices(for: moment)
            let release: [VoiceRequest] = if case let .press(group, _) = moment { voicing.voices(for: .release(group)) } else { [] }
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == mine else { return }
                    for request in requests { self.audio.play(request.key, gain: request.gain * gain) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + time + 0.07) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == mine else { return }
                    for request in release { self.audio.play(request.key, gain: request.gain * gain) }
                }
            }
        }
    }

    // MARK: -

    /// A fling as the motion model answers it with the current threshold
    /// and intensity: a flick to 3000 pt/s, a quarter second held, then
    /// macOS-style momentum. So choosing a tuning changes what's felt.
    private func playGlide(_ mine: Int, feel: Bool = true, hear: Bool? = nil) {
        let withSound = hear ?? soundIsOn(for: .glide)
        let settings = store.value
        var model = MotionModel(tuning: .init(threshold: settings.motionThreshold, intensity: settings.motionIntensity))
        var speeds = (0..<8).map { 3000 * Double($0 + 1) / 8 } + Array(repeating: 3000.0, count: 30)
        var speed = 3000.0
        while speed > 40 { speed *= 0.985; speeds.append(speed) }
        var pulses: [(time: Double, pulse: MotionModel.Pulse)] = []
        for (index, speed) in speeds.enumerated() {
            let time = Double(index) / 120
            if let pulse = model.update(delta: -speed / 120, time: time) { pulses.append((time, pulse)) }
        }
        let start = pulses.first?.time ?? 0
        for (time, pulse) in pulses {
            DispatchQueue.main.asyncAfter(deadline: .now() + time - start) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == mine else { return }
                    let cue: Cue = pulse == .swell ? .swell : .glide
                    if feel { self.haptics.preview(cue) }
                    let level: Float = if case let .glide(level) = pulse { Float(level) } else { 1 }
                    if withSound { self.sound(cue, level: level) }
                }
            }
        }
    }

    private func soundIsOn(for cue: Cue) -> Bool {
        let settings = store.value
        return switch cue {
        case .glide, .swell: settings.motionSounds
        case .actionable, .action: settings.pageSounds && !settings.hapticsEnabled
        default: settings.pageSounds
        }
    }

    private func sound(_ cue: Cue, level: Float = 1) {
        guard SoundSynth.hasPageSound(cue) else { return }
        audio.prepareIfNeeded()
        var gain = max(store.value.cueVolume, 0.2) * level
        if cue == .glide || cue == .swell { gain *= store.value.motionIntensity.soundGain }
        audio.play(.page(cue), gain: gain)
    }
}
