#if DEBUG
import AppKit
import PulseCore
import QuartzCore
import SwiftUI

/// `Pulse --self-test` (debug builds only): drives the real pipelines with
/// simulated input, in real time, and checks what comes out. Haptics are
/// muted (the one-cue policy still runs), so nothing is felt and no window
/// is shown or scrolled.
enum SelfTest {
    static func run() -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var ok = true
        ok = retiredBoard() && ok
        ok = motionThroughPageDetector() && ok
        ok = tour() && ok
        ok = tourOpening() && ok
        ok = mediaQuiet() && ok
        ok = keyboardDemo() && ok
        ok = typingStep() && ok
        print(ok ? "Self-test passed" : "Self-test FAILED")
        return ok
    }

    private static func check(_ condition: Bool, _ message: String) -> Bool {
        print(condition ? "  ok   " : "  FAIL ", message)
        return condition
    }

    /// Settings saved with a board this Pulse doesn't have ("alloy", from an
    /// earlier version) load with the default board and every other setting
    /// as it was.
    private static func retiredBoard() -> Bool {
        print("Settings with a retired board")
        var saved = PulseSettings()
        saved.muted = true
        saved.waypointCues = true
        saved.hapticStrength = 0.75
        saved.pageSounds = true
        saved.motionThreshold = .late
        saved.cueVolume = 0.25
        saved.keyboardProfile = .mechanical
        saved.keyboardBoard = .brown
        saved.keyboardProfileChosen = true
        saved.keyReleaseSounds = true
        saved.keyboardVolume = 0.5
        saved.quietWhileMediaPlays = false
        saved.excludedApps = ["com.example.editor"]
        let encoded = (try? JSONEncoder().encode(saved)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let blob = encoded.replacingOccurrences(of: #""keyboardBoard":"brown""#, with: #""keyboardBoard":"alloy""#)
        var ok = check(blob != encoded && blob.contains(#""keyboardBoard":"alloy""#), "the saved settings name the Alloy board")
        guard let loaded = try? JSONDecoder().decode(PulseSettings.self, from: Data(blob.utf8)) else {
            return check(false, "they still decode")
        }
        var expected = saved
        expected.keyboardBoard = PulseSettings().keyboardBoard
        ok = check(loaded.keyboardBoard == .red, "they load with the default board (\(loaded.keyboardBoard))") && ok
        ok = check(loaded == expected, "and every other setting intact") && ok
        return ok
    }

    /// A trackpad fling into the page detector: precision, swell, glides,
    /// momentum heard but not felt.
    private static func motionThroughPageDetector() -> Bool {
        print("Motion through the page detector")
        let haptics = HapticOutput()
        haptics.isMuted = true
        let page = PageDetector(haptics: haptics)
        var options = PageDetector.Options()
        options.controls = false
        options.headings = false
        options.navigation = false
        options.cautions = false
        options.boundaries = false
        page.options = options
        var cues: [(Cue, CFTimeInterval)] = []
        page.onCue = { cue, _ in cues.append((cue, CACurrentMediaTime())) }

        // Off screen, so no window of Pulse's or anyone's is in the way.
        let location = CGPoint(x: -5000, y: -5000)
        var speeds: [Double] = Array(repeating: 250, count: 36) // 0.3 s of careful reading
        speeds += (0..<8).map { 250 + 2750 * Double($0 + 1) / 8 } // a flick
        speeds += Array(repeating: 3000, count: 20)
        var momentum = 3000.0
        var momentumStart = speeds.count
        while momentum > 40 { momentum *= 0.985; speeds.append(momentum) }
        momentumStart = momentumStart > 0 ? momentumStart : 0
        let fingersLift = 36 + 8 + 20

        let start = CACurrentMediaTime()
        var touchingGlides = 0
        var momentumGlides = 0
        for (index, speed) in speeds.enumerated() {
            let due = start + Double(index) / 120
            while CACurrentMediaTime() < due { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            let touching = index < fingersLift
            let before = cues.count
            page.simulateScroll(ScrollEvent(
                deltaY: -speed / 120,
                phase: touching ? (index == 0 ? 1 : 2) : 0,
                momentumPhase: touching ? 0 : (index == fingersLift ? 1 : 2),
                location: location,
                time: CACurrentMediaTime(),
                eventTime: CACurrentMediaTime()
            ))
            if cues.count > before, cues.last?.0 == .glide {
                if touching { touchingGlides += 1 } else { momentumGlides += 1 }
            }
        }
        let names = cues.map(\.0)
        let quietRead = cues.allSatisfy { $0.1 - start > 0.3 }
        let swells = names.filter { $0 == .swell }.count
        let glides = names.filter { $0 == .glide }.count
        let times = cues.map(\.1)
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        var ok = check(quietRead, "careful reading stays silent")
        ok = check(swells == 1 && names.first == .swell, "the flick is one swell, first (\(swells))") && ok
        ok = check(glides >= 5, "sustained speed glides (\(glides) glides)") && ok
        ok = check(momentumGlides > 0, "momentum keeps gliding, heard only (\(momentumGlides))") && ok
        ok = check(gaps.allSatisfy { $0 >= 0.06 }, "never closer than 60 ms (min \(Int((gaps.min() ?? 0) * 1000)) ms)") && ok
        ok = check(gaps.count > 2 && gaps.last! > gaps.dropFirst().min()! + 0.04, "the glide thins as it slows") && ok
        ok = check((gaps.first ?? 1) < 0.16, "the glide follows the swell without a gap") && ok
        _ = touchingGlides
        print("       cues:", cues.map { "\($0.0.rawValue)@\(Int((($0.1 - start) * 1000).rounded()))" }.joined(separator: " "))
        print("       gaps:", gaps.map { String(Int(($0 * 1000).rounded())) }.joined(separator: " "), "ms")
        return ok
    }

    /// The on-screen keyboard in Settings › Keyboard: real key events light keys
    /// and ask for the right voices, keys stay in the demo except ⌘ shortcuts,
    /// other windows are left alone, clicks work, and Pulse's live typing sound
    /// stands aside only while it's listening. Nothing is played aloud.
    private static func keyboardDemo() -> Bool {
        print("Keyboard demo")
        let suite = "com.millerroberts.Pulse.selftest"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.keyboardEnabled = true
        store.value.keyboardProfile = .mechanical
        store.value.keyReleaseSounds = true
        let haptics = HapticOutput()
        haptics.isMuted = true
        let previewer = CuePreviewer(haptics: haptics, audio: CueAudio(), store: store)
        var heard: [VoiceKey] = []
        previewer.typedForTesting = { heard += $0.map(\.key) }
        var standAside: [Bool] = []
        let model = TypingDemoModel(store: store, previewer: previewer) { standAside.append($0) }
        model.ignoresKeyWindow = true
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        model.attach(to: window)
        model.start()

        func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in number: Int? = nil) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: number ?? window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: code)!
        }

        let downPasses = model.handle(key(.keyDown, 0))
        let lit = model.pressed.contains(0)
        let upPasses = model.handle(key(.keyUp, 0))
        var ok = check(lit && !model.pressed.contains(0) && !downPasses && !upPasses, "a typed key lights while down, and stays in the demo")
        ok = check(heard == [.boardPress(.text), .boardRelease(.text)], "it sounds a key press and release (\(heard))") && ok

        heard = []
        let returnPasses = model.handle(key(.keyDown, 36))
        _ = model.handle(key(.keyUp, 36))
        ok = check(!returnPasses && heard.first == .boardPress(.returnKey), "Return sounds as Return and stays in the demo") && ok
        ok = check(model.handle(key(.keyDown, 12, .command)), "⌘ shortcuts go on to the app") && ok
        _ = model.handle(key(.keyUp, 12, .command))

        heard = []
        ok = check(model.handle(key(.keyDown, 1, in: window.windowNumber + 1)) && heard.isEmpty, "keys meant for other windows are left alone") && ok

        store.value.keyboardProfile = .keySense
        heard = []
        let capsWasOn = model.capsLock
        model.click(57, down: true)
        model.click(57, down: false)
        ok = check(heard == [.keySense(capsWasOn ? .capsLockOff : .capsLockOn)] && model.capsLock != capsWasOn, "clicking Caps Lock toggles it, with its KeySense cue") && ok
        model.click(57, down: true)
        model.click(57, down: false)
        heard = []
        model.click(49, down: true)
        model.click(49, down: false)
        ok = check(heard == [.keySense(.space)] && model.pressed.isEmpty, "clicking a key plays it once and lets it go") && ok

        // Through the app's own event queue and the local monitor.
        heard = []
        NSApp.postEvent(key(.keyDown, 2), atStart: false)
        NSApp.postEvent(key(.keyUp, 2), atStart: false)
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        ok = check(heard == [.keySense(.text)], "typing reaches it through the app's event monitor (\(heard))") && ok

        model.stop()
        ok = check(standAside == [true, false], "live typing sound stands aside while it listens, and comes back (\(standAside))") && ok
        return ok
    }

    /// Another process playing (silent) audio quiets Pulse, and it comes back
    /// after playback stops.
    private static func mediaQuiet() -> Bool {
        print("Quiet while other audio plays")
        guard MediaMonitor.isSupported else { return check(true, "skipped: needs macOS 14.2") }
        let monitor = MediaMonitor()
        var changes: [Bool] = []
        monitor.onChange = { changes.append(monitor.isPlaying) }
        monitor.start()
        // Music or a video already playing would read the same as the test's.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if monitor.isPlaying {
            monitor.stop()
            return check(true, "skipped: another app is already playing audio")
        }
        changes = []
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-silence.wav")
        try? silentWAV(seconds: 4).write(to: wav)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav.path]
        try? player.run()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let during = monitor.isPlaying
        player.waitUntilExit()
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        let after = monitor.isPlaying
        monitor.stop()
        try? FileManager.default.removeItem(at: wav)
        var ok = check(during, "quiet while it plays")
        ok = check(!after, "back once it stops") && ok
        ok = check(changes == [true, false], "one change each way (\(changes))") && ok
        return ok
    }

    private static func silentWAV(seconds: Double) -> Data {
        let rate = 44_100
        let frames = Int(Double(rate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        data.append(Data(count: frames * 2))
        return data
    }

    /// The setup's tour, on the live detector's rules: each heading and the
    /// highlight pulse once on the way down, then the end; pointing and
    /// clicking cue as on a live page, and not just after a scroll.
    private static func tour() -> Bool {
        print("Setup tour")
        let size = CGSize(width: 776, height: 360)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = TourScrollView()
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        var t: CFTimeInterval = 100
        view.clock = { t }
        var cues: [Cue] = []
        view.onCue = { cue, _, _ in cues.append(cue) }

        view.simulatePointing(at: "Save Changes")
        view.simulatePointing(at: "Get help")
        view.simulatePointing(at: "Delete Account…")
        let pointing = cues
        // Pointing, then tabbing onto the same control, or the reverse.
        cues = []
        view.simulateTabbing(to: "Delete Account…")
        view.simulateLeaving("Delete Account…")
        view.simulateTabbing(to: "Save Changes")
        view.simulatePointing(at: "Save Changes")
        view.simulateLeaving("Save Changes")
        let once = cues
        cues = []
        view.simulateClickInField()
        let field = cues
        cues = []
        view.simulateSelecting(row: 2)
        let list = cues

        // A slow swipe, 200 pt a second.
        cues = []
        let bottom = view.documentHeight - size.height
        var y: CGFloat = 0
        while y < bottom {
            t += 0.05
            y = min(y + 10, bottom)
            view.simulateScroll(to: y)
        }
        let down = cues
        cues = []
        view.simulatePointing(at: "Save Changes")
        let afterScroll = cues
        // Ends share a 1.5 s cooldown; a person takes longer than that to swipe back up.
        t += 1.6
        cues = []
        while y > 0 {
            t += 0.05
            y = max(y - 45, 0)
            view.simulateScroll(to: y)
        }
        let up = cues

        // A flick that lifts before the next heading reaches it on momentum.
        t += 1.6
        cues = []
        var checklist = TourChecklist()
        view.onCue = { cue, feel, _ in
            cues.append(cue)
            checklist.played(cue, felt: feel)
        }
        var fingerDown = 3
        while cues.isEmpty, y < bottom {
            t += 0.05
            y = min(y + 10, bottom)
            view.simulateScroll(to: y, touching: fingerDown > 0)
            fingerDown -= 1
        }

        var ok = check(view.documentHeight > 2000, "the page scrolls (\(Int(view.documentHeight)) pt)")
        ok = check(pointing == [.action, .actionable, .caution], "button, link and destructive button: \(pointing.map(\.rawValue))") && ok
        ok = check(once == [.action], "a control pointed at and tabbed onto cues once: \(once.map(\.rawValue))") && ok
        ok = check(field == [.caution], "clicking the field with an error: \(field.map(\.rawValue))") && ok
        ok = check(list == [.navigation], "moving through the list: \(list.map(\.rawValue))") && ok
        // The last heading never reaches a third of the way down: the end is felt instead.
        let expected: [Cue] = [.landmark, .landmark, .waypoint, .landmark, .boundary]
        ok = check(down == expected, "each heading and the highlight once, then the end: \(down.map(\.rawValue))") && ok
        ok = check(afterScroll.isEmpty, "a button scrolled under the pointer stays silent") && ok
        ok = check(up.last == .boundary && up.filter { $0 == .boundary }.count == 1, "one landing back at the top: \(up.map(\.rawValue))") && ok
        ok = check(cues == [.landmark] && checklist.latest == .landmark && checklist.felt.isEmpty,
                   "a heading reached on momentum plays and is named, not ticked: \(cues.map(\.rawValue)), ticked \(checklist.felt.map(\.rawValue))") && ok
        window.close()
        return ok
    }

    /// The tour opens with nothing focused, so a click is what focuses the
    /// field and cues, and Tab still goes to the field first.
    private static func tourOpening() -> Bool {
        print("Setup tour opening")
        let suite = "com.millerroberts.Pulse.selftest"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let haptics = HapticOutput()
        haptics.isMuted = true
        let previewer = CuePreviewer(haptics: haptics, audio: CueAudio(), store: store)
        let model = SetupModel(store: store, previewer: previewer, tutorialOnly: true, keyboard: .playing)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: SetupWindowController.size),
                              styleMask: SetupWindowController.style, backing: .buffered, defer: false)
        // As the setup window is built.
        window.contentViewController = NSHostingController(rootView: SetupView(model: model, store: store))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        // What AppKit does as the window first comes on screen.
        window.makeFirstResponder(window.initialFirstResponder)
        let opened = window.firstResponder
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                     isARepeat: false, keyCode: 48)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let tabbed = (window.firstResponder as? NSTextView)?.delegate
        let initial = window.initialFirstResponder
        window.close()
        var ok = check(initial is TourScrollView && !(opened is NSText),
                       "it opens with nothing focused (\(opened.map { String(describing: type(of: $0)) } ?? "nil"))")
        ok = check(tabbed is NSTextField, "Tab goes to the email field") && ok
        return ok
    }

    /// The setup's typing step: Return in the box starts a new line, as in
    /// any text box, and doesn't press Continue; on other steps it does.
    private static func typingStep() -> Bool {
        print("Setup typing step")
        let suite = "com.millerroberts.Pulse.selftest"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let haptics = HapticOutput()
        haptics.isMuted = true
        let previewer = CuePreviewer(haptics: haptics, audio: CueAudio(), store: store)
        let model = SetupModel(store: store, previewer: previewer, tutorialOnly: true, keyboard: .playing)
        model.step = .typing
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: SetupWindowController.size),
                              styleMask: SetupWindowController.style, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SetupView(model: model, store: store))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        func textView(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(textView).first
        }
        /// Return as the app delivers a key-down: key equivalents first, then the focused view.
        func pressReturn() {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36)!
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        guard let box = window.contentView.flatMap(textView) else {
            return check(false, "the typing step has a text box")
        }
        window.makeFirstResponder(box)
        pressReturn()
        var ok = check(model.step == .typing && box.string.contains("\n"), "Return in the box starts a new line and stays on the step")
        // On the other steps it does: the step before typing is the tour.
        model.step = .tour
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.makeFirstResponder(nil)
        pressReturn()
        ok = check(model.step == .typing, "on the tour, Return presses Continue (\(model.step))") && ok
        window.close()
        return ok
    }
}
#endif
