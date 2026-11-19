import Testing
@testable import PulseCore

struct SetupStepTests {
    @Test func `setup tours first, then asks just before typing needs it`() {
        #expect(SetupStep.steps(tutorialOnly: false) == [.tour, .permission, .typing, .done])
    }

    @Test func `the tutorial has the same teaching steps without the permission`() {
        #expect(SetupStep.steps(tutorialOnly: true) == [.tour, .typing, .done])
    }
}

struct TourChecklistTests {
    @Test func `a cue ticks off once felt`() {
        var checklist = TourChecklist()
        checklist.played(.landmark, felt: true)
        checklist.played(.landmark, felt: true)
        #expect(checklist.felt == [.landmark])
        #expect(checklist.latest == .landmark)
    }

    @Test func `motion with no finger down is named but not ticked`() {
        var checklist = TourChecklist()
        checklist.played(.glide, felt: false)
        #expect(checklist.felt.isEmpty)
        #expect(checklist.latest == .glide)
        checklist.played(.glide, felt: true)
        #expect(checklist.felt == [.glide])
    }
}

struct TourCueTests {
    @Test(arguments: [
        ("AXLink", nil, "Get help", Cue.actionable),
        ("AXButton", nil, "Save Changes", .action),
        ("AXButton", nil, "Delete Account…", .caution),
    ] as [(String, String?, String, Cue)])
    func `pointing at a control cues as on live pages`(role: String, subrole: String?, label: String, expected: Cue) {
        #expect(TourCue.hover(role: role, subrole: subrole, label: label, sinceScroll: 2) == expected)
    }

    @Test func `fields, headings and list rows have no hover cue`() {
        #expect(TourCue.hover(role: "AXTextField", subrole: nil, label: nil, sinceScroll: 2) == nil)
        #expect(TourCue.hover(role: "AXHeading", subrole: nil, label: "Mailboxes", sinceScroll: 2) == nil)
        #expect(TourCue.hover(role: "AXRow", subrole: "AXTableRow", label: nil, sinceScroll: 2) == nil)
    }

    @Test func `a control scrolled under a still pointer stays silent`() {
        #expect(TourCue.hover(role: "AXButton", subrole: nil, label: "Save Changes", sinceScroll: 0.1) == nil)
        #expect(TourCue.hover(role: "AXButton", subrole: nil, label: "Save Changes", sinceScroll: TourCue.scrollSettle) == .action)
    }

    @Test func `a field with an error cues when focused, even by a click`() {
        #expect(TourCue.focus(role: "AXTextField", subrole: nil, label: nil, invalid: "true", sinceClick: 0) == .caution)
        #expect(TourCue.focus(role: "AXTextField", subrole: nil, label: nil, invalid: "false", sinceClick: 5) == nil)
    }

    @Test func `focus from Tab cues, focus from a click does not`() {
        #expect(TourCue.focus(role: "AXButton", subrole: nil, label: "Save Changes", invalid: nil, sinceClick: 5) == .action)
        #expect(TourCue.focus(role: "AXButton", subrole: nil, label: "Delete Account…", invalid: nil, sinceClick: 5) == .caution)
        #expect(TourCue.focus(role: "AXButton", subrole: nil, label: "Save Changes", invalid: nil, sinceClick: 0.1) == nil)
    }
}
