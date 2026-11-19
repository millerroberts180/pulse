import Foundation

/// Procedural, original sounds for every voice in the bank, rendered once at
/// launch into mono PCM. No recorded samples ship with Pulse: key sounds are
/// resynthesised from measured descriptions of real boards, and cues are
/// tones. Real recordings can replace any voice later.
public enum SoundSynth {
    /// Distinct takes per board key group, so repeated keys don't sound looped.
    public static let boardVariants = 4

    /// `board`: the keyboard Mechanical and Ambient sound like.
    public static func render(_ key: VoiceKey, variant: Int = 0, sampleRate: Double, board: KeyboardBoard = .creamy) -> [Float] {
        switch key {
        case let .boardPress(group):
            boardKey(board, group, release: false, variant: variant, sampleRate: sampleRate)
        case let .boardRelease(group):
            boardKey(board, group, release: true, variant: variant, sampleRate: sampleRate)
        case let .keySense(voice):
            tones(Self.keySense(voice), sampleRate: sampleRate)
        case .page(.glide):
            // A soft detent: the Creamy board's arrow-key sound, short and quiet, so
            // the glide sounds like part of the same instrument.
            render(Self.glideRecipe, timeScale: 0.6, seed: 0x611DE, sampleRate: sampleRate, gain: 0.10)
        case let .page(cue):
            tones(Self.page(cue), sampleRate: sampleRate)
        }
    }

    public static func variantCount(for key: VoiceKey) -> Int {
        switch key {
        case .boardPress, .boardRelease: boardVariants
        case .keySense, .page: 1
        }
    }

    /// Every voice the bank holds.
    public static var allVoices: [VoiceKey] {
        KeyGroup.allCases.flatMap { [VoiceKey.boardPress($0), .boardRelease($0)] }
            + KeySenseVoice.allCases.map { .keySense($0) }
            + Cue.allCases.filter(hasPageSound).map { .page($0) }
    }

    // MARK: - Board keys

    /// Mechanical and Ambient keys are rendered from measured boards (see
    /// Boards.swift); the glide borrows the Creamy board's arrow key, trimmed.
    static var glideRecipe: BoardRecipe {
        var recipe = BoardRecipes.recipe(.creamy, .navigation)
        recipe.length = 0.030
        return recipe
    }

    // MARK: - Tones (KeySense and page cues)

    struct Tone {
        var startHz: Double
        var endHz: Double
        var startMs: Double
        var lengthMs: Double
        var level: Double
        /// Second-harmonic share, for a slightly warmer, clearer pip.
        var harmonic: Double = 0.15
        var triangle = false
    }

    static func keySense(_ voice: KeySenseVoice) -> [Tone] {
        switch voice {
        // One low, stationary confirmation per state. No sweeps, arpeggios,
        // or high-frequency pips: KeySense should clarify an action, not turn
        // ordinary typing into a game-like soundtrack.
        case .text: [Tone(startHz: 310, endHz: 310, startMs: 0, lengthMs: 14, level: 0.075, harmonic: 0.05)]
        case .space: [Tone(startHz: 270, endHz: 270, startMs: 0, lengthMs: 16, level: 0.075, harmonic: 0.05)]
        case .returnKey: [Tone(startHz: 230, endHz: 230, startMs: 0, lengthMs: 26, level: 0.10, harmonic: 0.05)]
        case .delete: [Tone(startHz: 185, endHz: 185, startMs: 0, lengthMs: 24, level: 0.09, harmonic: 0.04)]
        case .navigation: [Tone(startHz: 340, endHz: 340, startMs: 0, lengthMs: 14, level: 0.07, harmonic: 0.05)]
        case .modifier: [Tone(startHz: 250, endHz: 250, startMs: 0, lengthMs: 18, level: 0.07, harmonic: 0.05)]
        case .chord: [Tone(startHz: 300, endHz: 300, startMs: 0, lengthMs: 22, level: 0.10, harmonic: 0.05)]
        case .capsLockOn: [Tone(startHz: 330, endHz: 330, startMs: 0, lengthMs: 34, level: 0.10, harmonic: 0.05)]
        case .capsLockOff: [Tone(startHz: 220, endHz: 220, startMs: 0, lengthMs: 34, level: 0.10, harmonic: 0.05)]
        case .repeatWarning: [Tone(startHz: 170, endHz: 170, startMs: 0, lengthMs: 34, level: 0.10, harmonic: 0.05)]
        }
    }

    /// Whether a cue has a sound of its own. Keyboard state cues sound
    /// through KeySense instead.
    public static func hasPageSound(_ cue: Cue) -> Bool {
        cue == .glide || page(cue) != nil
    }

    /// Optional quiet tones for page cues. Links and controls are hovered too
    /// often to deserve a sound alongside their haptic; theirs play only
    /// when haptics are off and the tone is the cue's only form.
    static func page(_ cue: Cue) -> [Tone]? {
        switch cue {
        case .actionable: [Tone(startHz: 660, endHz: 660, startMs: 0, lengthMs: 10, level: 0.06, harmonic: 0.05)]
        case .action: [Tone(startHz: 494, endHz: 494, startMs: 0, lengthMs: 18, level: 0.08, harmonic: 0.1)]
        case .waypoint: [
            Tone(startHz: 523, endHz: 523, startMs: 0, lengthMs: 45, level: 0.11),
            Tone(startHz: 784, endHz: 784, startMs: 110, lengthMs: 60, level: 0.12),
        ]
        case .swell: [Tone(startHz: 170, endHz: 250, startMs: 0, lengthMs: 150, level: 0.09, harmonic: 0.1)]
        case .landmark: [Tone(startHz: 392, endHz: 392, startMs: 0, lengthMs: 70, level: 0.16, harmonic: 0.25)]
        case .navigation: [Tone(startHz: 880, endHz: 880, startMs: 0, lengthMs: 14, level: 0.12)]
        case .caution: [
            Tone(startHz: 311, endHz: 311, startMs: 0, lengthMs: 40, level: 0.22),
            Tone(startHz: 311, endHz: 311, startMs: 95, lengthMs: 40, level: 0.22),
        ]
        case .boundary: [Tone(startHz: 330, endHz: 262, startMs: 0, lengthMs: 90, level: 0.16)]
        case .glide, .capsLockOn, .capsLockOff, .chord, .repeatWarning: nil
        }
    }

    static func tones(_ tones: [Tone]?, sampleRate: Double) -> [Float] {
        guard let tones, let end = tones.map({ $0.startMs + $0.lengthMs }).max() else { return [] }
        var out = [Float](repeating: 0, count: max(1, Int(end / 1000 * sampleRate)))
        let twoPi = 2 * Double.pi
        for tone in tones {
            let start = Int(tone.startMs / 1000 * sampleRate)
            let frames = Int(tone.lengthMs / 1000 * sampleRate)
            var phase = 0.0
            for i in 0..<frames where start + i < out.count {
                let progress = Double(i) / Double(max(frames - 1, 1))
                let hz = tone.startHz + (tone.endHz - tone.startHz) * progress
                phase += twoPi * hz / sampleRate
                let fundamental = tone.triangle ? (2 / Double.pi) * asin(sin(phase)) : sin(phase)
                let sample = fundamental + tone.harmonic * sin(2 * phase)
                // Raised-cosine envelope: no clicks at either end.
                let envelope = 0.5 - 0.5 * cos(twoPi * progress)
                out[start + i] += Float(sample * envelope * tone.level / (1 + tone.harmonic))
            }
        }
        return out
    }

    // MARK: - Shared

    /// Normalizes to the recipe's gain with gentle saturation.
    static func finish(_ samples: [Float], gain: Double, drive: Double) -> [Float] {
        let peak = samples.map { abs($0) }.max() ?? 0
        guard peak > 0 else { return samples }
        let normalizer = tanh(drive)
        return samples.map { sample in
            Float(tanh(drive * Double(sample / peak)) / normalizer * gain)
        }
    }
}

/// Deterministic randomness, so every launch renders identical sounds.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in -1...1.
    mutating func signed() -> Double {
        Double(next() >> 11) / Double(1 << 53) * 2 - 1
    }
}
