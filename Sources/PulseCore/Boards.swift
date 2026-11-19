import Foundation

/// The keyboard Mechanical (and Ambient) sound like. Each is a measured
/// description of a real board's sound, resynthesised from fresh noise, so no
/// recording ships with Pulse. The references were Mechvibes community packs,
/// measured only (credited in THIRD_PARTY_NOTICES.md): Creamy from "Creamy thingy", Velvet from an FR4-plate
/// board with very smooth linears, Citrus from a mix of creamy linears, Alloy
/// from a gasket-mounted aluminium board, Crisp from a magnetic-switch board.
public enum KeyboardBoard: String, Sendable, CaseIterable, Codable {
    /// Soft, muted, and short: the classic creamy linear. The default.
    case creamy
    /// Smoother still, with almost no edge.
    case velvet
    /// Creamy with a little more pop.
    case citrus
    /// A heavier aluminium board with a longer ring.
    case alloy
    /// Brighter and clackier, with more low end.
    case crisp
}

/// One key group's sound on a board: band levels (dB) over time.
struct BoardRecipe: Sendable {
    /// [band][moment], in dB relative to the loudest cell. A cell at the
    /// floor is silence.
    var levels: [[Double]]
    var length: Double
    /// dB: each group as loud against its board's letter keys as on the
    /// real board (softened), and each board's letters as loud as Creamy's.
    var loudness: Double
    /// The narrowest a low band may be, Hz. Narrow low bands ring, like a
    /// metal case; wide ones stop quickly, like a creamy thock.
    var width: Double
}

enum BoardRecipes {
    /// As stored in BoardRecipeData.swift: hex bytes of dB − floor, band-major.
    struct Encoded: Sendable {
        var levels: String
        var length: Double
        var loudness: Double
        var width: Double
    }

    static let floor = -72.0

    /// Each band is two identical band-pass stages in series: a third of an
    /// octave wide, and never narrower than `width`.
    static func q(_ hz: Double, width: Double) -> Double {
        min(2.8, 0.6436 * hz / width)
    }

    static func recipe(_ board: KeyboardBoard, _ group: KeyGroup) -> BoardRecipe {
        decoded[board]?[group] ?? decoded[.creamy]![.text]!
    }

    private static let decoded: [KeyboardBoard: [KeyGroup: BoardRecipe]] = table.mapValues { groups in
        groups.mapValues { encoded in
            var bytes: [Double] = []
            var index = encoded.levels.startIndex
            while index < encoded.levels.endIndex {
                let next = encoded.levels.index(index, offsetBy: 2)
                bytes.append(Double(UInt8(encoded.levels[index..<next], radix: 16) ?? 0) + floor)
                index = next
            }
            let moments = times.count
            let levels = (0..<bands.count).map { band in Array(bytes[band * moments..<(band + 1) * moments]) }
            return BoardRecipe(levels: levels, length: encoded.length, loudness: encoded.loudness, width: encoded.width)
        }
    }
}

extension SoundSynth {
    /// A key on a board: 21 independent noise bands, each shaped by its
    /// measured level over time and only then band-passed, so a quick low
    /// thock stays low instead of splattering up into the mids. Noise, not
    /// tones: real keystrokes are many tiny resonances blurred together, and
    /// pure tones in the 1–3 kHz tick ring like metal.
    static func boardKey(_ board: KeyboardBoard, _ group: KeyGroup, release: Bool, variant: Int, sampleRate: Double, gain: Double = 0.34) -> [Float] {
        var recipe = BoardRecipes.recipe(board, group)
        var timeScale = 1.0
        if release {
            // The upstroke: quieter, quicker, lighter in the low end.
            recipe.levels = zip(BoardRecipes.bands, recipe.levels).map { hz, row in
                row.map { $0 <= BoardRecipes.floor ? $0 : max($0 - (hz < 350 ? 6 : 0), BoardRecipes.floor) }
            }
            recipe.length *= 0.6
            recipe.loudness -= 9
            timeScale = 0.65
        }
        // Deterministic, so every launch renders the same takes.
        let seed = UInt64(KeyboardBoard.allCases.firstIndex(of: board)!) &* 104_729
            &+ UInt64(KeyGroup.allCases.firstIndex(of: group)!) &* 977
            &+ UInt64(variant) &* 7919 &+ (release ? 0xA5A5 : 0)
        return render(recipe, timeScale: timeScale, seed: seed, sampleRate: sampleRate, gain: gain * pow(10, recipe.loudness / 20))
    }

    static func render(_ recipe: BoardRecipe, timeScale: Double, seed: UInt64, sampleRate: Double, gain: Double) -> [Float] {
        synthesize(recipe, timeScale: timeScale, seed: seed, sampleRate: sampleRate, gain: gain).samples
    }

    /// The render, and how much energy each band put into it.
    private static func synthesize(_ recipe: BoardRecipe, timeScale: Double, seed: UInt64, sampleRate: Double, gain: Double) -> (samples: [Float], energy: [Double]) {
        let count = max(1, Int(recipe.length * sampleRate))
        var energy = [Double](repeating: 0, count: BoardRecipes.bands.count)
        var out = [Double](repeating: 0, count: count)
        let times = BoardRecipes.times.map { $0 * timeScale }
        // Every band needs its own, independent noise. (Seeding them with
        // seed + band × SplitMix's own increment would make each band the
        // same sequence one sample apart: correlated bands interfere through
        // their overlapping skirts and tilt the tone.)
        var seeds = SplitMix(seed: seed)
        let bandSeeds = BoardRecipes.bands.map { _ in seeds.next() }
        for (band, hz) in BoardRecipes.bands.enumerated() where hz < sampleRate * 0.45 {
            let row = recipe.levels[band]
            guard let loudest = row.max(), loudest > BoardRecipes.floor + 0.5 else { continue }
            let filter = Biquad.bandPass(hz: hz, q: BoardRecipes.q(hz, width: recipe.width), sampleRate: sampleRate)
            let unit = Biquad.noiseRMS(cascading: filter)
            var first = filter, second = filter
            var noise = SplitMix(seed: bandSeeds[band])
            var moment = 0
            for i in 0..<count {
                let t = Double(i) / sampleRate
                while moment + 1 < times.count - 1, t > times[moment + 1] { moment += 1 }
                let level: Double
                if t >= times[times.count - 1] {
                    level = row[row.count - 1]
                } else {
                    let span = times[moment + 1] - times[moment]
                    let mix = span > 0 ? min(max((t - times[moment]) / span, 0), 1) : 0
                    level = row[moment] + (row[moment + 1] - row[moment]) * mix
                }
                let shaped = level > BoardRecipes.floor + 0.5 ? noise.signed() * pow(10, level / 20) : 0
                let filtered = second.process(first.process(shaped)) / unit
                out[i] += filtered
                energy[band] += filtered * filtered
            }
        }
        // Gentle edges: a 50 Hz high-pass for rumble, a soft 5 ms tail.
        let highPass = exp(-2 * Double.pi * 50 / sampleRate)
        var inPrevious = 0.0, outPrevious = 0.0
        let fade = 0.005 * sampleRate
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            outPrevious = highPass * (outPrevious + out[i] - inPrevious)
            inPrevious = out[i]
            samples[i] = Float(outPrevious * min(Double(count - 1 - i) / fade, 1))
        }
        // Barely any saturation: clipping noise peaks would add fizz.
        return (finish(samples, gain: gain, drive: 0.3), energy)
    }

    /// See `KeyboardBoard.signature`.
    fileprivate static let signatures: [KeyboardBoard: [Double]] = Dictionary(uniqueKeysWithValues: KeyboardBoard.allCases.map { board in
        let bands = synthesize(BoardRecipes.recipe(board, .text), timeScale: 1, seed: 1, sampleRate: 48_000, gain: 1).energy
        let pairs = stride(from: 0, to: bands.count, by: 2).map { bands[$0..<min($0 + 2, bands.count)].reduce(0, +) }
        let top = max(pairs.max() ?? 1, 1e-12)
        // Square-rooted so quiet bands still show.
        return (board, pairs.map { sqrt($0 / top) })
    })
}

/// A second-order filter (RBJ cookbook, transposed direct form II).
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0

    /// Band-pass with 0 dB at its centre.
    static func bandPass(hz: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * hz / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// RMS of uniform noise in −1…1 through two of these in series:
    /// √(Σh² / 3) over the cascade's impulse response.
    static func noiseRMS(cascading filter: Biquad) -> Double {
        var first = filter, second = filter
        first.z1 = 0; first.z2 = 0; second.z1 = 0; second.z2 = 0
        var energy = 0.0
        for i in 0..<8192 {
            let h = second.process(first.process(i == 0 ? 1 : 0))
            energy += h * h
        }
        return max(sqrt(energy / 3), 1e-9)
    }
}

extension KeyboardBoard {
    /// The board's tone, for drawing: how much energy a letter key puts into
    /// each pair of bands (two-thirds of an octave, low to high), scaled so
    /// the loudest is 1.
    public var signature: [Double] {
        SoundSynth.signatures[self] ?? []
    }
}
