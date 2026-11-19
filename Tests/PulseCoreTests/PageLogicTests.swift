import CoreGraphics
import Testing
@testable import PulseCore

struct ClassifierTests {
    @Test(arguments: [
        ("AXButton", nil, ElementKind.button),
        ("AXLink", nil, .link),
        ("AXCheckBox", nil, .toggle),
        ("AXRadioButton", "AXTabButton", .tab),
        ("AXCheckBox", "AXSwitch", .toggle),
        ("AXPopUpButton", nil, .menuItem),
        ("AXHeading", nil, .heading),
        ("AXTextField", "AXSecureTextField", .field),
        ("AXRow", "AXOutlineRow", .button),
    ] as [(String, String?, ElementKind)])
    func `roles map to kinds`(role: String, subrole: String?, expected: ElementKind) {
        #expect(ElementClassifier.kind(role: role, subrole: subrole) == expected)
    }

    @Test func `generic roles need a press action`() {
        #expect(ElementClassifier.kind(role: "AXGroup", subrole: nil) == nil)
        #expect(ElementClassifier.isPressable(actions: ["AXPress"]))
        #expect(ElementClassifier.isPressable(actions: ["AXOpen"]))
        #expect(!ElementClassifier.isPressable(actions: ["AXShowMenu", "AXScrollToVisible"]))
    }

    @Test func `window-sized pressables are not controls`() {
        #expect(ElementClassifier.isControlSized(CGRect(x: 0, y: 0, width: 120, height: 32)))
        #expect(!ElementClassifier.isControlSized(CGRect(x: 0, y: 0, width: 1200, height: 800)))
        #expect(!ElementClassifier.isControlSized(CGRect(x: 0, y: 0, width: 600, height: 300)))
    }

    @Test func `destructive labels on actions, not on links`() {
        #expect(CautionDetector.isDestructive(kind: .button, subrole: nil, label: "Delete repository"))
        #expect(CautionDetector.isDestructive(kind: .menuItem, subrole: nil, label: "Move to Trash"))
        #expect(!CautionDetector.isDestructive(kind: .link, subrole: nil, label: "Remove old docs"))
        #expect(!CautionDetector.isDestructive(kind: .button, subrole: nil, label: "Undelete"))
        #expect(!CautionDetector.isDestructive(kind: .button, subrole: nil, label: String(repeating: "delete this ", count: 5)))
        #expect(CautionDetector.isDestructive(kind: .button, subrole: "AXCloseButton", label: nil))
    }

    @Test func `only plain invalid is an error`() {
        #expect(CautionDetector.isInvalid("true"))
        #expect(!CautionDetector.isInvalid("spelling"))
        #expect(!CautionDetector.isInvalid(nil))
    }

    @Test func `control kinds tell an importance story`() {
        #expect(ControlCueClassifier.cue(for: .link) == .actionable)
        #expect(ControlCueClassifier.cue(for: .otherClickable) == .actionable)
        #expect(ControlCueClassifier.cue(for: .button) == .action)
        #expect(ControlCueClassifier.cue(for: .toggle) == .action)
        #expect(ControlCueClassifier.cue(for: .tab) == .action)
        #expect(ControlCueClassifier.cue(for: .field) == nil)
    }
}

struct ControlMemoryTests {
    @Test func `a label inside the cued control is the same control`() {
        var memory = ControlMemory()
        memory.remember(CGRect(x: 100, y: 100, width: 120, height: 32))
        let label = CGRect(x: 110, y: 106, width: 60, height: 18)
        let r1 = memory.absorbs(frame: label, isClickable: false, at: CGPoint(x: 120, y: 110))
        #expect(r1)
    }

    @Test func `a re-rendered control shifted by an animation is the same`() {
        var memory = ControlMemory()
        memory.remember(CGRect(x: 100, y: 100, width: 120, height: 32))
        let shifted = CGRect(x: 104, y: 102, width: 120, height: 32)
        let r2 = memory.absorbs(frame: shifted, isClickable: true, at: CGPoint(x: 150, y: 115))
        #expect(r2)
    }

    @Test func `a neighbouring control is new`() {
        var memory = ControlMemory()
        memory.remember(CGRect(x: 100, y: 100, width: 120, height: 32))
        let neighbour = CGRect(x: 222, y: 100, width: 120, height: 32)
        let r3 = memory.absorbs(frame: neighbour, isClickable: true, at: CGPoint(x: 260, y: 115))
        #expect(!r3)
    }

    @Test func `an inert window-sized container outside the control ends it`() {
        var memory = ControlMemory()
        memory.remember(CGRect(x: 100, y: 100, width: 120, height: 32))
        let window = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let r4 = memory.absorbs(frame: window, isClickable: false, at: CGPoint(x: 600, y: 500))
        #expect(!r4)
    }
}

struct LandmarkTrackerTests {
    @Test func `a heading crossing the reading line cues once`() {
        var tracker = LandmarkTracker()
        // Viewport 0...900, reading line at 300.
        let r5 = tracker.update(headings: [HeadingSample(id: 1, level: 2, top: 400)], viewportTop: 0, viewportBottom: 900, now: 0)
        #expect(r5 == nil)
        let crossed = tracker.update(headings: [HeadingSample(id: 1, level: 2, top: 250)], viewportTop: 0, viewportBottom: 900, now: 0.1)
        #expect(crossed?.id == 1)
        let r6 = tracker.update(headings: [HeadingSample(id: 1, level: 2, top: 100)], viewportTop: 0, viewportBottom: 900, now: 1)
        #expect(r6 == nil)
    }

    @Test func `deep headings stay silent`() {
        var tracker = LandmarkTracker()
        _ = tracker.update(headings: [HeadingSample(id: 1, level: 5, top: 400)], viewportTop: 0, viewportBottom: 900, now: 0)
        let r7 = tracker.update(headings: [HeadingSample(id: 1, level: 5, top: 200)], viewportTop: 0, viewportBottom: 900, now: 0.1)
        #expect(r7 == nil)
    }

    @Test func `several crossings yield one cue for the most important heading`() {
        var tracker = LandmarkTracker()
        let before = [HeadingSample(id: 1, level: 3, top: 320), HeadingSample(id: 2, level: 1, top: 340)]
        let after = [HeadingSample(id: 1, level: 3, top: 100), HeadingSample(id: 2, level: 1, top: 120)]
        _ = tracker.update(headings: before, viewportTop: 0, viewportBottom: 900, now: 0)
        let r8 = tracker.update(headings: after, viewportTop: 0, viewportBottom: 900, now: 0.1)
        #expect(r8?.id == 2)
    }

    @Test func `cues are rate limited`() {
        var tracker = LandmarkTracker()
        _ = tracker.update(headings: [HeadingSample(id: 1, level: 2, top: 400), HeadingSample(id: 2, level: 2, top: 700)], viewportTop: 0, viewportBottom: 900, now: 0)
        let r9 = tracker.update(headings: [HeadingSample(id: 1, level: 2, top: 200), HeadingSample(id: 2, level: 2, top: 500)], viewportTop: 0, viewportBottom: 900, now: 0.1)
        #expect(r9 != nil)
        let r10 = tracker.update(headings: [HeadingSample(id: 1, level: 2, top: 0), HeadingSample(id: 2, level: 2, top: 280)], viewportTop: 0, viewportBottom: 900, now: 0.2)
        #expect(r10 == nil)
    }
}

struct BoundaryTrackerTests {
    let bottom = EdgeState(atTop: false, atBottom: true)
    let middle = EdgeState(atTop: false, atBottom: false)

    @Test func `arriving at the end cues once and never while held`() {
        var tracker = BoundaryTracker()
        let r11 = tracker.update(edges: middle, direction: .down, isNewGesture: false, now: 0)
        #expect(!r11)
        let r12 = tracker.update(edges: bottom, direction: .down, isNewGesture: false, now: 0.1)
        #expect(r12)
        let r13 = tracker.update(edges: bottom, direction: .down, isNewGesture: false, now: 0.2)
        #expect(!r13)
        let r14 = tracker.update(edges: bottom, direction: .down, isNewGesture: false, now: 5)
        #expect(!r14)
    }

    @Test func `a fresh push into the end cues again after the cooldown`() {
        var tracker = BoundaryTracker()
        let r15 = tracker.update(edges: bottom, direction: .down, isNewGesture: true, now: 0)
        #expect(r15)
        let r16 = tracker.update(edges: bottom, direction: .down, isNewGesture: true, now: 0.5)
        #expect(!r16)
        let r17 = tracker.update(edges: bottom, direction: .down, isNewGesture: true, now: 2)
        #expect(r17)
    }

    @Test func `leaving the end re-arms it`() {
        var tracker = BoundaryTracker()
        let r18 = tracker.update(edges: bottom, direction: .down, isNewGesture: false, now: 0)
        #expect(r18)
        let r19 = tracker.update(edges: middle, direction: .up, isNewGesture: false, now: 1)
        #expect(!r19)
        let r20 = tracker.update(edges: bottom, direction: .down, isNewGesture: false, now: 2)
        #expect(r20)
    }

    @Test func `content that fits has no ends`() {
        var tracker = BoundaryTracker()
        let r21 = tracker.update(edges: EdgeState(atTop: true, atBottom: true), direction: .down, isNewGesture: true, now: 0)
        #expect(!r21)
    }

    @Test func `edge state from a scroll bar and from frames`() {
        #expect(EdgeState(scrollBarValue: 1).atBottom)
        #expect(EdgeState(scrollBarValue: 0).atTop)
        let fits = EdgeState(documentTop: 100, documentBottom: 600, viewportTop: 100, viewportBottom: 900)
        #expect(fits.atTop && fits.atBottom)
    }
}

struct CueTests {
    @Test func `scaling clamps to safe amplitudes`() {
        let firm = Cue.caution.shape.scaled(by: 3)
        #expect(firm.pulses.allSatisfy { $0.amplitude <= HapticShape.maximumAmplitude })
        let faint = Cue.actionable.shape.scaled(by: 0.01)
        #expect(faint.pulses.allSatisfy { $0.amplitude >= HapticShape.minimumAmplitude })
    }

    @Test(arguments: [Float(0.7), 1, 1.3, 1.8], [Cue.actionable, .action, .navigation, .landmark, .glide, .swell])
    func `hover, selection, and motion cues are one pulse`(strength: Float, cue: Cue) {
        // Several public patterns in a row feel like a double or triple click.
        #expect(cue.shape.publicPulses(strength: strength).count == 1)
    }

    @Test(arguments: [Float(0.7), 1, 1.3, 1.8])
    func `a control is never lighter than a link, and a glide is the faintest cue`(strength: Float) {
        let pattern = { (cue: Cue) in cue.shape.publicPulses(strength: strength)[0].pattern }
        #expect(pattern(.action) >= pattern(.actionable))
        #expect(pattern(.glide) == .alignment)
        #expect(pattern(.swell) >= pattern(.glide))
    }

    @Test func `at the default strength a control is firmer than a link`() {
        let pattern = { (cue: Cue) in cue.shape.publicPulses(strength: 1.3)[0].pattern }
        #expect(pattern(.actionable) == .generic)
        #expect(pattern(.action) == .levelChange)
    }

    @Test func `a waypoint rises, unlike a caution or a boundary`() {
        let waypoint = Cue.waypoint.shape.publicPulses(strength: 1).map(\.pattern)
        #expect(waypoint == [.alignment, .generic])
        let boundary = Cue.boundary.shape.publicPulses(strength: 1.3).map(\.pattern)
        #expect(boundary.first! > boundary.last!)
    }

    @Test func `an echo that wouldn't be lighter is dropped`() {
        let flat = HapticShape([
            .init(amplitude: 1, durationMs: 2, fallback: .faint),
            .init(amplitude: 1, durationMs: 2, offsetMs: 40, fallback: .faint),
        ])
        #expect(flat.publicPulses(strength: 1).count == 1)
    }

    @Test func `caution stays a distinct strong double`() {
        let pulses = Cue.caution.shape.publicPulses(strength: 1)
        #expect(pulses.map(\.pattern) == [.levelChange, .levelChange])
    }

    @Test func `caution outranks the ordinary tick`() {
        #expect(Cue.caution.priority > Cue.actionable.priority)
        #expect(Cue.action.priority > Cue.actionable.priority)
        #expect(Cue.boundary.priority > Cue.landmark.priority)
        // Motion never drowns out meaning.
        #expect(Cue.allCases.filter { $0 != .glide }.allSatisfy { $0.priority > Cue.glide.priority })
    }
}

struct ClickWaveformTests {
    @Test func `silencing keeps the pulse's length and zeroes its amplitude`() {
        // The release click a MacBook Pro trackpad reports.
        #expect(ClickWaveform.silenced([0x01, 0x12, 0xA8]) == [0x01, 0x00, 0xA8])
        #expect(ClickWaveform.isSilent([0x01, 0x00, 0xA8]))
        #expect(!ClickWaveform.isSilent([0x01, 0x12, 0xA8]))
    }

    @Test(arguments: [
        [UInt8](),
        [0x01, 0x12],
        [0x02, 0x12, 0xA8],
        // The press click: a longer form Pulse never rewrites.
        [0x01, 0x1E, 0xA8, 0x02, 0x00, 0x30, 0x0E, 0x15, 0x01, 0x00, 0x62, 0x22, 0x22],
    ])
    func `unknown forms are left alone`(report: [UInt8]) {
        #expect(ClickWaveform.silenced(report) == nil)
        #expect(!ClickWaveform.isSilent(report))
    }
}
