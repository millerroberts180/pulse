import AppKit
import PulseCore
import QuartzCore
import SwiftUI

/// The setup's tour: a fake web page you swipe down through. Each section
/// plays its cue as it reaches the cue line a third of the way down (where
/// live headings cue), and its element flashes so the feel and the thing it
/// means arrive together. A stretch near the end is for flicking fast (swell
/// and glide), and the bottom is the page end. Links and buttons also cue on
/// hover, as on live pages.
///
/// It runs Pulse's own trackers on its own geometry, so it needs no
/// permission; the live detectors skip Pulse's windows.
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

final class TourScrollView: NSScrollView {
    /// Where cues happen: a third of the way down, like the live reading line.
    static let cueLine: CGFloat = 1.0 / 3.0

    var onCue: ((Cue, Bool, Float) -> Void)?

    private struct Section {
        var anchor: NSView
        var cue: Cue?
        var flash: HighlightView?
        var arrive: (() -> Void)?
    }

    private let document = FlippedView()
    private var blocks: [(view: NSView, gapBefore: CGFloat)] = []
    private var sections: [Section] = []
    private var lastTops: [CGFloat?] = []
    private var boundaries = BoundaryTracker()
    private var motion = MotionModel()
    private var direction: ScrollDirection = .down
    private var newGesture = false
    private var lastOrigin: CGFloat = 0
    private var lastScroll: CFTimeInterval = -.infinity
    private var tabs: NSSegmentedControl?

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
    /// UI snapshots open the tour scrolled this far, mid-page.
    static var snapshotScroll: CGFloat?
    private var snapshotScrolled = false
    #endif

    // MARK: - Content

    private func build() {
        add(label("Swipe down", size: 22, weight: .bold), gap: 12)
        add(text("Rest two fingers on the trackpad and scroll slowly. Each section plays its cue as it reaches the line."), gap: 4)
        let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.down", accessibilityDescription: nil) ?? NSImage())
        arrow.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.imageAlignment = .alignLeft
        add(arrow, gap: 70)

        let heading = label("A new section begins", size: 20, weight: .semibold)
        section("Heading", anchor: heading, cue: .landmark, content: [
            heading,
            text("One soft pulse as a heading passes the line. Pulse marks main headings only, so long pages stay calm."),
        ])

        let link = CueButton(title: "a link like this one", cue: .actionable, style: .link) { [weak self] in self?.hovered($0) }
        section("Link", cue: .actionable, flashing: link, content: [
            row([text("Here is"), link]),
            text("One light tick. Move the pointer onto it to feel it again."),
        ])

        let save = CueButton(title: "Save Changes", cue: .action, style: .push) { [weak self] in self?.hovered($0) }
        section("Control", cue: .action, flashing: save, content: [
            row([save]),
            text("One firmer tick: a button, switch, tab, or menu that does something."),
        ])

        let delete = CueButton(title: "Delete Account…", cue: .caution, style: .destructive) { [weak self] in self?.hovered($0) }
        section("Caution", cue: .caution, flashing: delete, content: [
            row([delete]),
            text("Two strong pulses: destructive actions, fields with errors, and alerts."),
        ])

        let tabs = NSSegmentedControl(labels: ["Inbox", "Drafts", "Sent", "Archive"], trackingMode: .selectOne, target: self, action: #selector(tabClicked))
        tabs.selectedSegment = 0
        self.tabs = tabs
        section("Navigation", cue: .navigation, flashing: tabs, arrive: { [weak self] in self?.advanceTab() }, content: [
            row([tabs]),
            text("One crisp tick when the selected item in a sidebar, list, or tab strip changes. Click a tab."),
        ])

        let marked = NSTextField(labelWithAttributedString: Self.highlighted())
        marked.lineBreakMode = .byWordWrapping
        section("Waypoint", cue: .waypoint, flashing: marked, content: [
            marked,
            text("A rising pair for find-in-page matches and highlighted text. Optional, and off until you turn it on."),
        ])

        let flick = label("Now swipe down fast, and keep swiping", size: 20, weight: .semibold)
        section("Glide and swell", anchor: flick, cue: nil, content: [
            flick,
            text("A burst of speed swells. Keep your fingers moving fast and it glides: faint pulses that come closer as you speed up and fade as you slow. Once your fingers lift, the page coasts silently."),
        ])
        for index in 0..<18 {
            add(SkeletonCard(lines: 3 + index % 2), gap: 18)
        }

        let end = label("The end of the page", size: 20, weight: .semibold)
        section("Page end", anchor: end, cue: nil, content: [
            end,
            text("A landing, then a settle: there's no more page this way. It never repeats while you hold there. Scroll back up to feel the top."),
        ])
        add(spacer(24), gap: 0)
    }

    private func section(
        _ name: String, anchor: NSView? = nil, cue: Cue?, flashing: NSView? = nil,
        arrive: (() -> Void)? = nil, content: [NSView]
    ) {
        let eyebrow = label(name.uppercased(), size: 11, weight: .semibold)
        eyebrow.textColor = .controlAccentColor
        add(eyebrow, gap: 230)
        var highlight: HighlightView?
        for (index, view) in content.enumerated() {
            if let flashing, view === flashing || (view as? NSStackView)?.views.contains(flashing) == true {
                let flash = HighlightView()
                document.addSubview(flash, positioned: .below, relativeTo: nil)
                flash.target = flashing
                highlight = flash
            }
            add(view, gap: index == 0 ? 6 : 8)
        }
        sections.append(Section(anchor: anchor ?? eyebrow, cue: cue, flash: highlight, arrive: arrive))
        lastTops.append(nil)
    }

    private func add(_ view: NSView, gap: CGFloat = 10) {
        blocks.append((view, gap))
        document.addSubview(view)
    }

    private func layoutDocument() {
        let width = contentView.bounds.width
        let column = min(520, width - 48)
        let x = (width - column) / 2
        var y: CGFloat = 0
        for (view, gap) in blocks {
            y += gap
            if let label = view as? NSTextField { label.preferredMaxLayoutWidth = column }
            let height: CGFloat = switch view {
            case let spacer as SpacerView: spacer.height
            case let card as SkeletonCard: card.height
            default: view.fittingSize.height
            }
            let fitted = view is NSStackView ? min(view.fittingSize.width, column) : column
            view.frame = CGRect(x: x, y: y, width: fitted, height: height)
            y += height
        }
        // The last section can reach the cue line before the page ends.
        let tail = max(contentView.bounds.height * (1 - Self.cueLine) - 120, 0)
        document.frame = CGRect(x: 0, y: 0, width: width, height: y + tail)
        for section in sections { section.flash?.follow() }
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
        stack.spacing = 6
        return stack
    }

    private func spacer(_ height: CGFloat) -> SpacerView { SpacerView(height: height) }

    private static func highlighted() -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
        let result = NSMutableAttributedString(string: "Somewhere in the middle of a paragraph, ", attributes: base)
        var mark = base
        mark[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.45)
        result.append(NSAttributedString(string: "a highlighted phrase", attributes: mark))
        result.append(NSAttributedString(string: " passes the line.", attributes: base))
        return result
    }

    // MARK: - Cues

    private func hovered(_ cue: Cue) {
        // A control sliding under a still pointer stays silent, as on live pages.
        guard CACurrentMediaTime() - lastScroll > 0.3 else { return }
        onCue?(cue, true, 1)
    }

    @objc private func tabClicked() {
        onCue?(.navigation, true, 1)
    }

    private func advanceTab() {
        guard let tabs else { return }
        tabs.selectedSegment = (tabs.selectedSegment + 1) % tabs.segmentCount
    }

    override func scrollWheel(with event: NSEvent) {
        lastScroll = CACurrentMediaTime()
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        if delta != 0 { direction = delta < 0 ? .down : .up }
        if event.phase == .began { motion.newGesture(); newGesture = true }
        let touching = event.phase != [] && event.momentumPhase == []
        if let pulse = motion.update(delta: delta, time: event.timestamp) {
            switch pulse {
            case .swell: onCue?(.swell, touching, 1)
            case let .glide(level): onCue?(.glide, touching, Float(level))
            }
        }
        super.scrollWheel(with: event)
    }

    @objc private func boundsChanged() {
        let visible = contentView.bounds
        guard visible.minY != lastOrigin else { return }
        lastOrigin = visible.minY
        let now = CACurrentMediaTime()
        let edges = EdgeState(atTop: visible.minY <= 0.5, atBottom: visible.maxY >= document.frame.height - 0.5)
        let isNew = newGesture
        newGesture = false
        if direction == .down ? edges.atBottom : edges.atTop { motion.hold() }
        if boundaries.update(edges: edges, direction: direction, isNewGesture: isNew, now: now) {
            onCue?(.boundary, true, 1)
        }
        // A section's cue plays as its top crosses the line, either way.
        let line = visible.height * Self.cueLine
        for index in sections.indices {
            let top = sections[index].anchor.frame.minY - visible.minY
            defer { lastTops[index] = top }
            guard let previous = lastTops[index], (previous - line) * (top - line) < 0 || (top == line && previous != line) else { continue }
            sections[index].arrive?()
            sections[index].flash?.flash()
            if let cue = sections[index].cue { onCue?(cue, true, 1) }
        }
    }

    #if DEBUG
    /// The self-test scrolls the page directly.
    func simulateScroll(to y: CGFloat, direction: ScrollDirection) {
        self.direction = direction
        contentView.scroll(to: CGPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
        boundsChanged()
    }

    var documentHeight: CGFloat { document.frame.height }
    #endif
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SpacerView: NSView {
    let height: CGFloat
    init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
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

/// A soft accent glow behind an element, flashed as its cue plays.
private final class HighlightView: NSView {
    weak var target: NSView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        alphaValue = 0
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func follow() {
        guard let target, let superview, let container = target.superview else { return }
        frame = superview.convert(target.frame, from: container).insetBy(dx: -8, dy: -6)
    }

    func flash() {
        follow()
        alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }
    }
}

/// A button that cues as the pointer moves onto it, once per entry.
private final class CueButton: NSButton {
    enum Style { case link, push, destructive }

    private let cue: Cue
    private let onCue: (Cue) -> Void

    init(title: String, cue: Cue, style: Style, onCue: @escaping (Cue) -> Void) {
        self.cue = cue
        self.onCue = onCue
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(pressed)
        switch style {
        case .link:
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onCue(cue)
    }

    @objc private func pressed() {}
}
