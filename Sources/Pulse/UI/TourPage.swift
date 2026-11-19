import AppKit
import PulseCore
import QuartzCore
import SwiftUI

/// The setup's tour: a short page with a link, two buttons, a field with an
/// error, a list, headings, highlighted text, a stretch to scroll fast, and
/// an end. Pulse's detectors never read Pulse's own windows, so the page
/// cues itself, on the triggers the detectors use and by their rules
/// (`TourCue`): the pointer moving onto a link or button, focus landing on
/// the field, the list's selection changing, and, as it scrolls, Pulse's own
/// trackers on its geometry (headings and highlights passing the reading
/// line, the ends, the motion model). So it needs no permission.
struct TourPage: NSViewRepresentable {
    var onCue: (Cue, _ feel: Bool, _ level: Float) -> Void

    func makeNSView(context: Context) -> TourScrollView {
        let view = TourScrollView()
        view.onCue = onCue
        return view
    }

    func updateNSView(_ view: TourScrollView, context: Context) {
        view.onCue = onCue
    }
}

final class TourScrollView: NSScrollView, NSTextFieldDelegate {
    var onCue: ((Cue, Bool, Float) -> Void)?
    /// The tour's time; the self-test steps its own.
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }

    private struct Block {
        var view: NSView
        var gap: CGFloat
        /// Nil: the column's width.
        var width: CGFloat?
    }

    private let document = FlippedView()
    private var blocks: [Block] = []
    private var headings: [TourHeading] = []
    private var marks: [NSView] = []
    private let field = TourField()
    private let error = NSTextField(labelWithString: "Enter an email address with an @.")
    private let list = TourList()
    private var landmarks = LandmarkTracker()
    private var highlights = LandmarkTracker()
    private var boundaries = BoundaryTracker()
    private var motion = MotionModel()
    private var direction: ScrollDirection = .down
    private var newGesture = false
    private var lastOrigin: CGFloat = 0
    private var lastScroll: CFTimeInterval = -.infinity
    private var lastWheel: CFTimeInterval = -.infinity
    private var lastNavigation: CFTimeInterval = -.infinity

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 700, height: 320))
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        borderType = .noBorder
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView
        )
        build()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layoutDocument()
        #if DEBUG
        if let y = Self.snapshotScroll, !snapshotScrolled {
            snapshotScrolled = true
            contentView.scroll(to: CGPoint(x: 0, y: y))
            reflectScrolledClipView(contentView)
        }
        #endif
    }

    #if DEBUG
    /// UI snapshots open the tour scrolled this far.
    static var snapshotScroll: CGFloat?
    private var snapshotScrolled = false
    #endif

    // MARK: - Content

    private func build() {
        heading("Your account", level: 1, gap: 18)
        add(text("Point at each button and at the link. Then click in the field."), gap: 6)
        add(label("Email", size: 12, weight: .medium), gap: 16)
        field.stringValue = "robin.example.com"
        field.delegate = self
        field.page = self
        field.cell?.setAccessibilityLabel("Email")
        add(field, gap: 4, width: 280)
        error.font = .systemFont(ofSize: 11)
        error.textColor = .systemRed
        add(error, gap: 4)
        let save = TourControl(title: "Save Changes", style: .push, page: self)
        let delete = TourControl(title: "Delete Account…", style: .destructive, page: self)
        let help = TourControl(title: "Get help", style: .link, page: self)
        add(row([save, delete, help]), gap: 14)

        heading("Mailboxes", level: 2, gap: 44)
        add(text("Click a mailbox, or use the arrow keys to move through the list."), gap: 6)
        list.onSelect = { [weak self] in self?.selectionChanged() }
        add(list, gap: 10, width: 220)

        heading("Scroll slowly", level: 2, gap: 44)
        add(text("Each heading pulses once as it passes a third of the way down."), gap: 6)
        let marked = NSTextField(wrappingLabelWithString: "")
        marked.attributedStringValue = Self.highlighted()
        marked.isSelectable = false
        marks.append(marked)
        add(marked, gap: 10)

        heading("Scroll fast", level: 2, gap: 44)
        add(text("Swipe fast and keep your fingers moving."), gap: 6)
        for index in 0..<18 {
            add(SkeletonCard(lines: 3 + index % 2), gap: 18)
        }

        heading("End of the page", level: 2, gap: 44)
        add(text("Scroll back up to feel the top."), gap: 6)
    }

    private func heading(_ string: String, level: Int, gap: CGFloat) {
        let heading = TourHeading(string, level: level)
        headings.append(heading)
        add(heading, gap: gap)
    }

    private func add(_ view: NSView, gap: CGFloat, width: CGFloat? = nil) {
        blocks.append(Block(view: view, gap: gap, width: width))
        document.addSubview(view)
    }

    private func layoutDocument() {
        let width = contentView.bounds.width
        let column = min(520, width - 48)
        let x = (width - column) / 2
        var y: CGFloat = 0
        for block in blocks {
            y += block.gap
            let view = block.view
            if let label = view as? NSTextField, !label.isEditable { label.preferredMaxLayoutWidth = column }
            let height: CGFloat = switch view {
            case let card as SkeletonCard: card.height
            case let list as TourList: list.height
            default: view.fittingSize.height
            }
            let fitted = view is NSStackView ? min(view.fittingSize.width, column) : min(block.width ?? column, column)
            view.frame = CGRect(x: x, y: y, width: fitted, height: height)
            y += height
        }
        document.frame = CGRect(x: 0, y: 0, width: width, height: y + 28)
    }

    private func label(_ string: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byWordWrapping
        return label
    }

    private func text(_ string: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        return label
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        return stack
    }

    private static func highlighted() -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
        var mark = base
        mark[.foregroundColor] = NSColor.labelColor
        mark[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.45)
        let result = NSMutableAttributedString(string: "Highlighted text", attributes: mark)
        result.append(NSAttributedString(
            string: " pulses there too, as a waypoint. Waypoints are off until you turn them on in Settings › Cues.",
            attributes: base
        ))
        return result
    }

    // MARK: - Cues

    private func play(_ cue: Cue, feel: Bool = true, level: Float = 1) {
        onCue?(cue, feel, level)
    }

    /// The pointer moved onto a link or button.
    fileprivate func pointed(at control: NSButton) {
        let (role, subrole) = Self.roles(of: control)
        let cue = TourCue.hover(role: role, subrole: subrole, label: control.title, sinceScroll: clock() - lastScroll)
        if let cue { play(cue) }
    }

    /// Keyboard focus landed on a control or the field. Only focus a click
    /// or a key moved counts: a window's first focus wasn't anyone's doing.
    fileprivate func focused(_ view: NSView, by event: NSEvent.EventType?) {
        guard event == .leftMouseDown || event == .keyDown else { return }
        let (role, subrole) = Self.roles(of: view)
        let cue = TourCue.focus(
            role: role, subrole: subrole, label: (view as? NSButton)?.title, invalid: (view as? TourField)?.invalid,
            sinceClick: event == .leftMouseDown ? 0 : .infinity
        )
        if let cue { play(cue) }
    }

    /// The role and subrole the accessibility tree reports, which for a
    /// control is its cell's.
    private static func roles(of view: NSView) -> (String, String?) {
        let shown = NSAccessibility.unignoredDescendant(of: view) as? NSAccessibilityProtocol ?? view
        return (shown.accessibilityRole()?.rawValue ?? "", shown.accessibilitySubrole()?.rawValue)
    }

    private func selectionChanged() {
        let now = clock()
        guard now - lastNavigation >= TourCue.navigationInterval else { return }
        lastNavigation = now
        play(.navigation)
    }

    func controlTextDidChange(_ notification: Notification) {
        error.isHidden = field.invalid != "true"
    }

    override func scrollWheel(with event: NSEvent) {
        let now = clock()
        let gap = now - lastWheel
        lastWheel = now
        lastScroll = now
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        // Trackpads mark a new gesture; wheel notches start one after a pause.
        let discrete = event.phase == [] && event.momentumPhase == []
        if event.phase == .began || (discrete && gap > 0.35) { newGesture = true }
        if event.phase == .began { motion.newGesture() }
        let touching = event.phase != [] && event.momentumPhase == []
        if let pulse = motion.update(delta: delta, time: event.timestamp) {
            switch pulse {
            case .swell: play(.swell, feel: touching)
            case let .glide(level): play(.glide, feel: touching, level: Float(level))
            }
        }
        super.scrollWheel(with: event)
    }

    @objc private func boundsChanged() {
        let visible = contentView.bounds
        guard visible.minY != lastOrigin else { return }
        direction = visible.minY > lastOrigin ? .down : .up
        lastOrigin = visible.minY
        // Content moving under a still pointer: what slides beneath it stays silent.
        lastScroll = clock()
        probe(visible)
    }

    /// One look at the page as it scrolls, in the order the live detector
    /// looks: the ends, then highlights, then headings, one cue at most.
    private func probe(_ visible: CGRect) {
        let now = clock()
        let edges = EdgeState(atTop: visible.minY <= 0.5, atBottom: visible.maxY >= document.frame.height - 0.5)
        let isNewGesture = newGesture
        newGesture = false
        // Nothing left to travel: the bounce glides no further.
        if !(edges.atTop && edges.atBottom), direction == .down ? edges.atBottom : edges.atTop { motion.hold() }
        if boundaries.update(edges: edges, direction: direction, isNewGesture: isNewGesture, now: now) {
            return play(.boundary)
        }
        // Where each sits in the viewport, as the live detector reads it on screen.
        func onScreen(_ view: NSView) -> Double { Double(view.frame.minY - visible.minY) }
        let height = Double(visible.height)
        let marked = marks.enumerated().map { HeadingSample(id: $0.offset, level: nil, top: onScreen($0.element)) }
        if highlights.update(headings: marked, viewportTop: 0, viewportBottom: height, now: now) != nil {
            return play(.waypoint)
        }
        let samples = headings.enumerated().map { HeadingSample(id: $0.offset, level: $0.element.level, top: onScreen($0.element)) }
        if landmarks.update(headings: samples, viewportTop: 0, viewportBottom: height, now: now) != nil {
            play(.landmark)
        }
    }

    #if DEBUG
    /// The self-test scrolls, points and clicks directly.
    func simulateScroll(to y: CGFloat) {
        contentView.scroll(to: CGPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
        boundsChanged()
    }

    func simulatePointing(at title: String) {
        if let control = document.subviews.lazy.compactMap({ $0 as? NSStackView }).flatMap(\.views)
            .compactMap({ $0 as? TourControl }).first(where: { $0.title == title }) {
            pointed(at: control)
        }
    }

    func simulateClickInField() {
        focused(field, by: .leftMouseDown)
    }

    func simulateSelecting(row: Int) {
        list.selectRowIndexes([row], byExtendingSelection: false)
    }

    var documentHeight: CGFloat { document.frame.height }
    #endif
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A section heading, exposed to VoiceOver as one.
private final class TourHeading: NSTextField {
    let level: Int

    init(_ string: String, level: Int) {
        self.level = level
        super.init(frame: .zero)
        stringValue = string
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: level == 1 ? 22 : 18, weight: level == 1 ? .bold : .semibold)
        cell?.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
    }

    required init?(coder: NSCoder) { nil }
}

/// A link or button that cues as the pointer moves onto it, once per entry,
/// and as keyboard focus lands on it.
private final class TourControl: NSButton {
    enum Style { case link, push, destructive }

    private let style: Style
    private weak var page: TourScrollView?

    init(title: String, style: Style, page: TourScrollView) {
        self.style = style
        self.page = page
        super.init(frame: .zero)
        self.title = title
        switch style {
        case .link:
            cell?.setAccessibilityRole(.link)
            isBordered = false
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: 13),
            ])
        case .push:
            bezelStyle = .push
        case .destructive:
            bezelStyle = .push
            hasDestructiveAction = true
            contentTintColor = .systemRed
        }
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        if style == .link { addCursorRect(bounds, cursor: .pointingHand) } else { super.resetCursorRects() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        page?.pointed(at: self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { page?.focused(self, by: NSApp.currentEvent?.type) }
        return became
    }
}

/// An email field whose error shows until the address has an @.
private final class TourField: NSTextField {
    weak var page: TourScrollView?

    /// What a web page's `AXInvalid` would say.
    var invalid: String { stringValue.contains("@") ? "false" : "true" }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { page?.focused(self, by: NSApp.currentEvent?.type) }
        return became
    }
}

/// A list of mailboxes, like a mail app's sidebar.
private final class TourList: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    private let names = ["Inbox", "Drafts", "Sent", "Archive"]
    var onSelect: (() -> Void)?

    var height: CGFloat { CGFloat(names.count) * (rowHeight + intercellSpacing.height) }

    init() {
        super.init(frame: .zero)
        addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        headerView = nil
        style = .plain
        rowHeight = 24
        backgroundColor = .clear
        dataSource = self
        reloadData()
        selectRowIndexes([0], byExtendingSelection: false)
        // After the first selection, so only a person's changes cue.
        delegate = self
        setAccessibilityLabel("Mailboxes")
    }

    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: names[row])
        label.font = .systemFont(ofSize: 13)
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?()
    }
}

/// Placeholder content for the fast stretch, like a page still loading.
private final class SkeletonCard: NSView {
    let lines: Int
    var height: CGFloat { CGFloat(lines) * 18 + 26 }

    init(lines: Int) {
        self.lines = lines
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        for line in 0..<lines {
            let width = bounds.width * (line == lines - 1 ? 0.55 : 0.88) - 28
            NSBezierPath(roundedRect: CGRect(x: 14, y: 14 + CGFloat(line) * 18, width: width, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
        }
    }
}
