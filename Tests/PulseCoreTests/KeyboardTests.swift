import Darwin
import Testing
@testable import PulseCore

struct KeyClassifierTests {
    @Test(arguments: [
        (UInt16(0), KeyGroup.text), // A
        (49, .space),
        (36, .returnKey),
        (76, .returnKey),
        (51, .delete),
        (117, .delete),
        (123, .navigation),
        (48, .navigation),
        (55, .modifier),
        (57, .modifier),
    ] as [(UInt16, KeyGroup)])
    func `key codes map to groups`(code: UInt16, group: KeyGroup) {
        #expect(KeyClassifier.group(forKeyCode: code) == group)
    }
}

struct KeyInterpreterTests {
    @Test func `a command chord is recognised`() {
        var interpreter = KeyInterpreter()
        let moments = interpreter.interpret(KeyInput(keyCode: 8, kind: .down, modifiers: [.command], timestamp: 0))
        #expect(moments == [.press(.text, chord: true)])
    }

    @Test func `shift alone is not a chord`() {
        var interpreter = KeyInterpreter()
        let moments = interpreter.interpret(KeyInput(keyCode: 0, kind: .down, modifiers: [.shift], timestamp: 0))
        #expect(moments == [.press(.text, chord: false)])
    }

    @Test func `caps lock reports on and off`() {
        var interpreter = KeyInterpreter()
        let r1 = interpreter.interpret(KeyInput(keyCode: 57, kind: .flagsChanged, modifiers: [.capsLock], timestamp: 0))
        #expect(r1 == [.capsLock(on: true)])
        let r2 = interpreter.interpret(KeyInput(keyCode: 57, kind: .flagsChanged, modifiers: [], timestamp: 1))
        #expect(r2 == [.capsLock(on: false)])
    }

    @Test func `modifier presses and releases`() {
        var interpreter = KeyInterpreter()
        let r3 = interpreter.interpret(KeyInput(keyCode: 56, kind: .flagsChanged, modifiers: [.shift], timestamp: 0))
        #expect(r3 == [.press(.modifier, chord: false)])
        let r4 = interpreter.interpret(KeyInput(keyCode: 56, kind: .flagsChanged, modifiers: [], timestamp: 0.1))
        #expect(r4 == [.release(.modifier)])
    }

    @Test func `left and right modifiers are tracked separately`() {
        var interpreter = KeyInterpreter()
        let left = interpreter.interpret(KeyInput(keyCode: 56, kind: .flagsChanged, modifiers: [.shift], timestamp: 0))
        let right = interpreter.interpret(KeyInput(keyCode: 60, kind: .flagsChanged, modifiers: [.shift], timestamp: 0.1))
        // Left Shift comes up while right Shift still holds the flag.
        let leftUp = interpreter.interpret(KeyInput(keyCode: 56, kind: .flagsChanged, modifiers: [.shift], timestamp: 0.2))
        let rightUp = interpreter.interpret(KeyInput(keyCode: 60, kind: .flagsChanged, modifiers: [], timestamp: 0.3))
        #expect(left == [.press(.modifier, chord: false)])
        #expect(right == [.press(.modifier, chord: false)])
        #expect(leftUp == [.release(.modifier)])
        #expect(rightUp == [.release(.modifier)])
        // And the next press is a press again.
        let again = interpreter.interpret(KeyInput(keyCode: 56, kind: .flagsChanged, modifiers: [.shift], timestamp: 0.4))
        #expect(again == [.press(.modifier, chord: false)])
    }

    @Test func `a missed modifier release doesn't turn the next press into a release`() {
        var interpreter = KeyInterpreter()
        _ = interpreter.interpret(KeyInput(keyCode: 55, kind: .flagsChanged, modifiers: [.command], timestamp: 0))
        // Command's key-up is hidden (a password field); typing shows it's up.
        _ = interpreter.interpret(KeyInput(keyCode: 0, kind: .down, modifiers: [], timestamp: 1))
        let press = interpreter.interpret(KeyInput(keyCode: 55, kind: .flagsChanged, modifiers: [.command], timestamp: 2))
        #expect(press == [.press(.modifier, chord: false)])
    }

    @Test func `caps lock state can be seeded from the keyboard`() {
        var interpreter = KeyInterpreter(modifiers: [.capsLock])
        let off = interpreter.interpret(KeyInput(keyCode: 57, kind: .flagsChanged, modifiers: [], timestamp: 0))
        #expect(off == [.capsLock(on: false)])
    }

    @Test func `a modifier held before Pulse started releases cleanly`() {
        var interpreter = KeyInterpreter()
        let up = interpreter.interpret(KeyInput(keyCode: 55, kind: .flagsChanged, modifiers: [], timestamp: 0))
        #expect(up == [.release(.modifier)])
    }

    @Test func `held delete warns early and is rate limited`() {
        var interpreter = KeyInterpreter()
        _ = interpreter.interpret(KeyInput(keyCode: 51, kind: .down, timestamp: 0))
        var warnings = 0
        for step in 1...20 {
            let moments = interpreter.interpret(KeyInput(keyCode: 51, kind: .down, isRepeat: true, timestamp: Double(step) * 0.05))
            warnings += moments.filter { $0 == .repeatWarning }.count
        }
        // 20 repeats over one second: first warning at the 3rd, then ≥0.8 s apart.
        #expect(warnings == 2)
    }

    @Test func `a new press resets the repeat count`() {
        var interpreter = KeyInterpreter()
        for step in 0..<2 {
            _ = interpreter.interpret(KeyInput(keyCode: 51, kind: .down, isRepeat: true, timestamp: Double(step)))
        }
        _ = interpreter.interpret(KeyInput(keyCode: 51, kind: .down, timestamp: 3))
        let moments = interpreter.interpret(KeyInput(keyCode: 51, kind: .down, isRepeat: true, timestamp: 4))
        #expect(!moments.contains(.repeatWarning))
    }
}

struct VoicingTests {
    @Test func `ambient is a uniform quiet key-down bed`() {
        let ambient = KeyboardVoicing(profile: .ambient)
        #expect(ambient.voices(for: .press(.space, chord: false)) == [VoiceRequest(key: .boardPress(.text), gain: 0.28)])
        #expect(ambient.voices(for: .release(.text)).isEmpty)
        #expect(ambient.voices(for: .heldRepeat(.text)).isEmpty)
        #expect(ambient.voices(for: .capsLock(on: true)).isEmpty)
    }

    @Test func `Mechanical keeps its old stored name, so saved settings carry over`() {
        #expect(KeyboardProfile(rawValue: "creamy") == .mechanical)
    }

    @Test func `mechanical voices presses, releases, and softer repeats`() {
        let mechanical = KeyboardVoicing(profile: .mechanical)
        #expect(mechanical.voices(for: .press(.space, chord: false)) == [VoiceRequest(key: .boardPress(.space), gain: 1)])
        #expect(mechanical.voices(for: .release(.text)) == [VoiceRequest(key: .boardRelease(.text), gain: 1)])
        #expect(mechanical.voices(for: .heldRepeat(.text)).first?.gain ?? 1 < 1)
        #expect(KeyboardVoicing(profile: .mechanical, releaseSounds: false).voices(for: .release(.text)).isEmpty)
    }

    @Test func `keysense gives categories and chord cues, never releases`() {
        let keySense = KeyboardVoicing(profile: .keySense)
        #expect(keySense.voices(for: .press(.delete, chord: false)).first?.key == .keySense(.delete))
        #expect(keySense.voices(for: .press(.text, chord: true)).first?.key == .keySense(.chord))
        #expect(keySense.voices(for: .release(.text)).isEmpty)
        #expect(keySense.voices(for: .capsLock(on: true)).first?.key == .keySense(.capsLockOn))
    }

    @Test func `quiet is silent`() {
        let quiet = KeyboardVoicing(profile: .quiet)
        #expect(quiet.voices(for: .press(.text, chord: false)).isEmpty)
        #expect(quiet.voices(for: .repeatWarning).isEmpty)
    }

    @Test func `state moments have haptic equivalents`() {
        #expect(KeyboardVoicing.hapticCue(for: .capsLock(on: true)) == .capsLockOn)
        #expect(KeyboardVoicing.hapticCue(for: .repeatWarning) == .repeatWarning)
        #expect(KeyboardVoicing.hapticCue(for: .press(.text, chord: false)) == nil)
    }
}

struct SynthTests {
    @Test func `KeySense state cues are low, single, stationary confirmations`() {
        for voice in KeySenseVoice.allCases {
            let tones = SoundSynth.keySense(voice)
            #expect(tones.count == 1)
            #expect(tones[0].startHz == tones[0].endHz)
            #expect(tones[0].startHz < 400)
        }
    }

    @Test(arguments: SoundSynth.allVoices)
    func `every voice renders a clean, bounded sound`(voice: VoiceKey) {
        let samples = SoundSynth.render(voice, sampleRate: 48_000)
        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(samples.contains { abs($0) > 0.01 })
        // No click at the end.
        #expect(abs(samples.last ?? 0) < 0.02)
    }

    @Test func `board key takes differ but are deterministic`() {
        let first = SoundSynth.render(.boardPress(.text), variant: 0, sampleRate: 48_000)
        let second = SoundSynth.render(.boardPress(.text), variant: 1, sampleRate: 48_000)
        #expect(first != second)
        #expect(first == SoundSynth.render(.boardPress(.text), variant: 0, sampleRate: 48_000))
    }
}

struct QuietRuleTests {
    @Test(arguments: ["com.spotify.client", "com.apple.WebKit.GPU", "com.apple.Music", "com.apple.avconferenced", "us.zoom.xos"])
    func `media and calls count`(bundleID: String) {
        #expect(!QuietRules.isIgnoredAudioSource(bundleID: bundleID))
    }

    @Test(arguments: ["systemsoundserverd", "com.apple.speech.speechsynthesisd", "com.apple.VoiceOver", "com.apple.universalaccessd", "com.apple.accessibility.heard"])
    func `alerts and speech never quiet Pulse`(bundleID: String) {
        #expect(QuietRules.isIgnoredAudioSource(bundleID: bundleID))
    }
}

struct FindAnnouncementTests {
    @Test(arguments: ["Result 1 of 3", "Result 3 of 3", "Ergebnis 2 von 7", "2/7", "3 of 12 matches"])
    func `a current match counts`(text: String) {
        #expect(FindAnnouncement.isMatch(text))
    }

    @Test(arguments: ["Result 0 of 3", "No results", "", "Found 3 results", "Result 4 of 3", "1 2 3"])
    func `no match, or not a find count`(text: String) {
        #expect(!FindAnnouncement.isMatch(text))
    }
}

struct BoardSoundTests {
    /// Spectral flatness (geometric over arithmetic mean of power) across
    /// 1–3 kHz in the first 30 ms: near 0 for ringing tones, which sound
    /// metallic (the old modal synthesis measured 0.004); 0.14–0.62 for the
    /// key groups of the recordings the boards are measured from, Red's the
    /// most tonal.
    private func flatness(_ samples: [Float], sampleRate: Double = 48_000) -> Double {
        let strike = Array(samples.prefix(Int(0.03 * sampleRate)))
        let n = strike.count
        var powers: [Double] = []
        for hz in stride(from: 1000.0, through: 3000.0, by: 25) {
            var re = 0.0, im = 0.0
            for (i, x) in strike.enumerated() {
                let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
                let phase = 2 * Double.pi * hz * Double(i) / sampleRate
                re += Double(x) * window * cos(phase)
                im -= Double(x) * window * sin(phase)
            }
            powers.append(re * re + im * im + 1e-20)
        }
        let geometric = exp(powers.map(log).reduce(0, +) / Double(powers.count))
        return geometric / (powers.reduce(0, +) / Double(powers.count))
    }

    @Test(arguments: KeyboardBoard.allCases)
    func `every board's keys are noise-like strikes, never ringing tones`(board: KeyboardBoard) {
        for group in KeyGroup.allCases {
            for key in [VoiceKey.boardPress(group), .boardRelease(group)] {
                let samples = SoundSynth.render(key, sampleRate: 48_000, board: board)
                #expect(samples.count > 500)
                #expect(samples.allSatisfy { abs($0) <= 1 && $0.isFinite })
                #expect(flatness(samples) > 0.1, "\(board) \(key) rings like a tone")
            }
        }
    }

    @Test func `Red is the default board`() {
        #expect(SoundSynth.render(.boardPress(.text), sampleRate: 48_000)
            == SoundSynth.render(.boardPress(.text), sampleRate: 48_000, board: .red))
        #expect(SoundSynth.render(.boardPress(.text), sampleRate: 48_000, board: .red)
            != SoundSynth.render(.boardPress(.text), sampleRate: 48_000, board: .black))
    }

    /// Saved settings then fall back to the default board (see
    /// `PulseSettings.init(from:)`, and the self-test's check of a whole blob).
    @Test(arguments: ["creamy", "velvet", "citrus", "alloy", "crisp"])
    func `boards earlier versions had no longer decode`(name: String) {
        #expect(KeyboardBoard(rawValue: name) == nil)
    }

    @Test func `each board draws a tone signature`() {
        for board in KeyboardBoard.allCases {
            #expect(board.signature.count == 11)
            #expect(board.signature.max() == 1)
        }
    }
}
