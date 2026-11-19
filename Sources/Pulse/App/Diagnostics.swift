import AppKit
import ApplicationServices
import PulseCore
import QuartzCore

/// `Pulse --diagnose`: reports what this Mac supports without playing a cue,
/// opening UI, or asking for permission. Output stays on this Mac.
enum Diagnostics {
    static func run() {
        let actuator = ActuatorDriver.make()
        print("Haptics:", actuator == nil ? "public API only (no actuator opened)" : "trackpad actuator opened")
        if let actuator {
            print("Custom pulses:", actuator.supportsCustomPulses ? "available" : "built-in patterns only")
        }

        let start = CACurrentMediaTime()
        let bank = SoundBank(sampleRate: 48_000, id: 0)
        let elapsed = (CACurrentMediaTime() - start) * 1000
        print(String(format: "Sound bank: %d voices, %.0f KB, rendered in %.1f ms",
                     SoundSynth.allVoices.count, Double(bank.byteCount) / 1024, elapsed))
        benchmarkMixer(bank)
        describeMotion()

        print("Accessibility:", AXIsProcessTrusted() ? "granted" : "not granted")
    }

    /// The glide a typical fling produces at each threshold: when motion
    /// starts, how many pulses, and how far apart, for tuning by feel.
    private static func describeMotion() {
        for threshold in MotionThreshold.allCases {
            var model = MotionModel(tuning: .init(threshold: threshold))
            // A two-finger flick: 60 ms to 3000 pt/s, 200 ms held, then
            // macOS-style momentum decay, at 120 Hz.
            var speeds = (0..<8).map { 3000 * Double($0 + 1) / 8 } + Array(repeating: 3000, count: 24)
            var speed = 3000.0
            while speed > 40 { speed *= 0.985; speeds.append(speed) }
            var pulses: [(Double, MotionModel.Pulse)] = []
            for (index, speed) in speeds.enumerated() {
                let time = Double(index) / 120
                if let pulse = model.update(delta: -speed / 120, time: time) { pulses.append((time, pulse)) }
            }
            let times = pulses.map(\.0)
            let gaps = zip(times, times.dropFirst()).map { Int((($1 - $0) * 1000).rounded()) }
            let swells = pulses.filter { $0.1 == .swell }.count
            print(String(format: "Motion (%@, %.0f pt/s): %d pulses over %.2f s, %d swell, gaps %@ ms",
                         threshold.rawValue, threshold.speed, pulses.count, (times.last ?? 0) - (times.first ?? 0), swells,
                         gaps.map(String.init).joined(separator: " ")))
        }
    }

    /// Times the render callback the way Core Audio calls it: 512-frame
    /// buffers, idle and with a burst of overlapping keystrokes.
    private static func benchmarkMixer(_ bank: SoundBank) {
        let mixer = Mixer()
        mixer.install(bank)
        let frames = 512
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { buffer.deallocate() }
        let clip = bank.clips(for: .boardPress(.text))[0]
        let rounds = 20_000

        func time(_ label: String, triggering voices: Int) {
            let start = CACurrentMediaTime()
            for round in 0..<rounds {
                if voices > 0, round % 4 == 0 {
                    for _ in 0..<voices {
                        mixer.enqueue(.init(start: clip.start, length: clip.length, gain: 0.3, bankID: bank.id, issued: mach_absolute_time()))
                    }
                }
                _ = mixer.render(frames: frames, into: buffer)
            }
            let perBuffer = (CACurrentMediaTime() - start) / Double(rounds) * 1_000_000
            let budget = Double(frames) / 48_000 * 1_000_000
            print(String(format: "Render callback (%@): %.2f µs per %d-frame buffer, %.3f%% of its %.0f µs budget",
                         label, perBuffer, frames, perBuffer / budget * 100, budget))
        }
        time("idle", triggering: 0)
        time("4 overlapping keys", triggering: 4)
    }

    /// `Pulse --probe`: after a short countdown, inspects what's under the
    /// pointer in the frontmost app, the way the page detector would. Prints
    /// roles, kinds, heading levels, and counts only, never text.
    static func probe(delay: TimeInterval = 3) {
        if !CommandLine.arguments.contains("--at") {
            print("Bring a page to the front and rest the pointer on it…")
            Thread.sleep(forTimeInterval: delay)
        }
        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted to this process.")
            return
        }
        // `--at x,y` probes a screen point (top-left coordinates) instead of the pointer.
        let arguments = CommandLine.arguments
        let given = arguments.firstIndex(of: "--at").flatMap { index -> CGPoint? in
            guard index + 1 < arguments.count else { return nil }
            let parts = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
        }
        guard let point = given ?? CGEvent(source: nil)?.location,
              let app = NSWorkspace.shared.frontmostApplication else { return }
        print("App:", app.localizedName ?? "?")

        let remaining = Countdown(2)
        let started = CACurrentMediaTime()
        let elapsed = { String(format: "%.1f ms", (CACurrentMediaTime() - started) * 1000) }
        let worker = AXWorker(
            onHover: { _, hit in
                print("Hover resolved after", elapsed())
                if let hit {
                    let kind = hit.kind.map(\.rawValue) ?? "not a control"
                    print("Under pointer:", kind, hit.caution ? "(caution)" : "", hit.enabled ? "" : "(disabled)")
                } else {
                    print("Under pointer: nothing resolvable")
                }
                remaining.count -= 1
            },
            onProbe: { probe in
                print("Scroll probe resolved after", elapsed(), "(includes the hover query ahead of it)")
                print("Page structure:", probe.pageAware ? "Page-aware" : "Motion-only")
                let levels = probe.headings.map { $0.level.map(String.init) ?? "?" }
                print("Headings near the viewport:", probe.headings.count, levels.isEmpty ? "" : "levels \(levels.joined(separator: ","))")
                print("Posts and articles near the viewport:", probe.articles.count)
                if let edges = probe.edges {
                    print("Scroll edges:", edges.atTop ? "at top" : "", edges.atBottom ? "at bottom" : "", !edges.atTop && !edges.atBottom ? "in the middle" : "")
                } else {
                    print("Scroll edges: not exposed")
                }
                remaining.count -= 1
            }
        )
        worker.hover(at: point)
        worker.probeScroll(at: point)
        let deadline = Date().addingTimeInterval(3)
        while remaining.count > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if remaining.count > 0 { print("No scrollable region under the pointer.") }

        // Warm cost: the same sample again, as when the pointer creeps across
        // one spot. One query at a time, like the live pipeline.
        let answered = Countdown(0)
        let warm = AXWorker(onHover: { _, _ in answered.count += 1 }, onProbe: { _ in })
        let rounds = 20
        let warmStart = CACurrentMediaTime()
        for round in 1...rounds {
            warm.hover(at: point)
            let deadline = Date().addingTimeInterval(0.5)
            while answered.count < round, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.0005))
            }
        }
        let perQuery = (CACurrentMediaTime() - warmStart) / Double(max(answered.count, 1)) * 1000
        print(String(format: "Repeated hover at the same spot: %.2f ms each over %d queries", perQuery, answered.count))
    }
}

private final class Countdown {
    var count: Int
    init(_ count: Int) { self.count = count }
}

#if DEBUG
extension Diagnostics {
    /// `Pulse --dump-sounds <folder>` (debug builds): every voice as a 48 kHz
    /// mono WAV, takes 0–3 for board keys, for listening to and measuring.
    static func dumpSounds(to folder: String) {
        let url = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for voice in SoundSynth.allVoices {
            for take in 0..<SoundSynth.variantCount(for: voice) {
                let samples = SoundSynth.render(voice, variant: take, sampleRate: 48_000)
                let name = "\(voice)".replacingOccurrences(of: "PulseCore.", with: "")
                    .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                try? wav(samples).write(to: url.appendingPathComponent("\(name)-\(take).wav"))
            }
        }
        print("Wrote \(SoundSynth.allVoices.count) voices to \(folder)")
    }

    private static func wav(_ samples: [Float], rate: Int = 48_000) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count * 2))
        for sample in samples { append(Int16(max(-1, min(1, sample)) * 32767)) }
        return data
    }
}
#endif
