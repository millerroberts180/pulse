import AppKit
import PulseCore
import QuartzCore
import os

/// Turns what the Accessibility system exposes about the frontmost page into
/// Pulse's page cues:
///
/// - **actionable**: the pointer enters, or keyboard focus lands on, a link
///   or generic pressable target (once per control, never while scrolling past);
/// - **action**: the same for controls that change state—buttons, toggles,
///   tabs, and menus—with a more substantial cue;
/// - **caution**: the same, but destructive, an invalid field, or an alert;
/// - **navigation**: the selected item in a sidebar, list, or tab strip changed;
/// - **landmark**: a heading crosses the reading line while scrolling;
/// - **boundary**: scrolling reached the start or end of the region;
/// - **waypoint** (opt-in): a find-in-page match, or highlighted text crossing
///   the reading line;
/// - **glide** and **swell**: motion scrolling, from scroll speed alone, so
///   they work on every page.
///
/// Everything is best effort: where an app exposes no document structure the
/// page is reported as Motion-only and only boundary and control cues remain.
///
/// Nothing listens that isn't needed: while muted, in an excluded app, or with
/// a cue family off, the corresponding event tap and observers don't exist.
final class PageDetector {
    struct Options: Equatable {
        var links = true
        var controls = true
        var headings = true
        var navigation = true
        var cautions = true
        var boundaries = true
        var waypoints = false
        var motion = true
        var glide = true
        var swell = true
        /// Motion pulses are felt as well as (optionally) heard.
        var motionHaptics = true
        var motionTuning = MotionModel.Tuning()
    }

    enum Awareness: Equatable {
        case unknown, pageAware, motionOnly
    }

    var options = Options() {
        didSet { if options != oldValue { refreshActivity() } }
    }
    /// Set while Pulse's own menu is open: hit-testing our own process off the
    /// main thread is unsafe, and there's nothing to feel there anyway.
    var isPaused = false {
        didSet { worker.setPaused(isPaused) }
    }
    /// Apps the user turned Pulse off in. The frontmost one is covered by
    /// `isExcluded`; this also silences their windows in the background,
    /// which can still be hovered and scrolled.
    var excludedApps: Set<String> = [] {
        didSet { if excludedApps != oldValue { exclusionByPID = [:] } }
    }
    /// Muted, haptics off, or the frontmost app is excluded by the user.
    var isExcluded = false {
        didSet {
            guard isExcluded != oldValue else { return }
            reset()
            refreshActivity()
        }
    }
    /// Called after a cue plays, with the cue and a level for its optional
    /// sound (1 except for glides, which soften as they speed up).
    var onCue: ((Cue, Float) -> Void)?
    /// Whether one of Pulse's own windows (or its menu-bar item) is in front
    /// at a point, in accessibility coordinates: never hit-tested.
    var isOwnWindow: (CGPoint) -> Bool = { _ in false }

    private let haptics: HapticOutput
    private let pointer = PointerTap()
    private let appObserver = AppObserver()
    private lazy var worker = AXWorker(
        onHover: { [weak self] point, hit in self?.handleHover(hit, at: point) },
        onProbe: { [weak self] probe in self?.handleProbe(probe) }
    )

    private var running = false
    private var memory = ControlMemory()
    private var lastElement: AXRef?
    private var landmarks = LandmarkTracker()
    private var highlights = LandmarkTracker()
    private var boundaries = BoundaryTracker()
    private var motion = MotionModel()
    private var lastFindMatch: CFTimeInterval = -.infinity
    private var currentPage: Int?
    private var currentRegion: Int?

    private var lastClick: CFTimeInterval = -.infinity
    /// After pressing a control that already cued on hover, the trackpad's own click is the feedback:
    /// Pulse's follow-up cues (a selection ripple, a menu item appearing under the pointer) wait until
    /// this time, so one press never feels like a double haptic.
    private var quietAfterClickUntil: CFTimeInterval = -.infinity
    private var lastScroll: CFTimeInterval = -.infinity
    private var lastNavigationCue: CFTimeInterval = -.infinity
    private var lastAlertCue: CFTimeInterval = -.infinity
    private var lastLiveRegionCheck: CFTimeInterval = -.infinity
    private var selectionCheckPending = false
    /// Keyboard focus is in a text field or combo box: autocomplete lists
    /// change selection on every keystroke, which is not navigation.
    private var focusInTextEntry = false
    private var scrollDirection: ScrollDirection?
    private var newGesturePending = false
    private var scrollPoint: CGPoint?
    private var probeTimer: Timer?
    private var lastProbe: CFTimeInterval = 0

    private(set) var awareness: [pid_t: Awareness] = [:]
    private var exclusionByPID: [pid_t: Bool] = [:]
    private let log = Logger(subsystem: "com.millerroberts.Pulse", category: "page")

    /// How often the scrolling region is probed for headings and edges.
    private static let probeInterval: CFTimeInterval = 0.125
    /// Pointer samples this soon after scrolling are "content moved under a
    /// still pointer", not the user reaching for a control.
    private static let scrollSettle: CFTimeInterval = 0.3

    init(haptics: HapticOutput) {
        self.haptics = haptics
        pointer.onMove = { [weak self] point in self?.pointerMoved(to: point) }
        pointer.onScroll = { [weak self] event in self?.scrolled(event) }
        pointer.onPress = { [weak self] point in self?.pressed(at: point) }
        pointer.onClick = { [weak self] point in self?.clicked(at: point) }
        appObserver.onFocus = { [weak self] ref in self?.focusChanged(ref) }
        appObserver.onSelectionChange = { [weak self] ref in self?.selectionChanged(ref) }
        appObserver.onLiveRegion = { [weak self] ref in self?.liveRegionChanged(ref) }
        appObserver.onFindSignal = { [weak self] ref, signal in self?.findSignal(ref, signal) }
    }

    var isRunning: Bool { running }

    func start() {
        running = true
        refreshActivity()
    }

    func stop() {
        running = false
        refreshActivity()
        reset()
    }

    func frontmostChanged() {
        reset()
        worker.invalidateContext() // A different window is likely in front.
        focusInTextEntry = false
        refreshActivity()
        // Activation posts no focus notification: ask what's focused now, so
        // an address bar that already has focus is known as text entry.
        if running, !isExcluded, options.navigation,
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            worker.inspectFocusedElement(ofApp: pid) { [weak self] finding in
                guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.focusInTextEntry = finding?.isTextEntry ?? false
            }
        }
    }

    /// An app quit: its per-app entries would otherwise live forever.
    func forget(pid: pid_t) {
        awareness.removeValue(forKey: pid)
        exclusionByPID.removeValue(forKey: pid)
    }

    private func isExcludedApp(_ pid: pid_t) -> Bool {
        if let known = exclusionByPID[pid] { return known }
        let excluded = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(excludedApps.contains) ?? false
        exclusionByPID[pid] = excluded
        return excluded
    }

    func awareness(for pid: pid_t?) -> Awareness {
        pid.flatMap { awareness[$0] } ?? .unknown
    }

    /// Starts exactly the listeners the current options need, and no others.
    private func refreshActivity() {
        let active = running && !isExcluded
        let hover = active && (options.links || options.controls || options.cautions)
        let scrollCues = active && (options.headings || options.boundaries || options.waypoints)
        let motion = active && options.motion
        // Hover needs scroll events too, to stay quiet while content moves.
        // Clicks matter to navigation (a click picks a list item) and to
        // the scroll cache (a click can bring another window forward).
        let clicks = active && (options.navigation || scrollCues)
        if !pointer.configure(moves: hover, scrolls: scrollCues || hover || motion, clicks: clicks) {
            log.error("Pointer event tap unavailable")
        }
        worker.configure(AXWorker.Options(
            cautions: options.cautions, headings: options.headings, edges: options.boundaries,
            highlights: options.waypoints
        ))
        self.motion.tuning = options.motionTuning
        // Scroll cues listen too: focus moving (Ctrl-Tab to another browser
        // tab) means the cached scroll region may be gone.
        let wantsNotifications = active && (options.links || options.controls || options.cautions || options.navigation || scrollCues)
        appObserver.observe(
            pid: wantsNotifications ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil,
            findMatches: options.waypoints
        )
        if !scrollCues {
            probeTimer?.invalidate()
            probeTimer = nil
        }
    }

    private func reset() {
        memory.reset()
        lastElement = nil
        landmarks.reset()
        highlights.reset()
        boundaries.reset()
        motion.reset()
        currentPage = nil
        currentRegion = nil
        newGesturePending = false
        pointer.skipRegion = nil
    }

    /// `feel`: whether the haptic should play. Momentum and mouse wheels
    /// move with no finger on the trackpad, so their motion cues are heard only.
    private func play(_ cue: Cue, feel: Bool = true, level: Float = 1) {
        // Cautions and ends still speak: they say something the click didn't.
        if CACurrentMediaTime() < quietAfterClickUntil, cue != .caution, cue != .boundary { return }
        guard haptics.play(cue, feel: feel) else { return }
        // Cue names only, at debug level (never stored unless someone streams it).
        log.debug("cue \(cue.rawValue, privacy: .public)\(feel ? "" : " (heard only)", privacy: .public)")
        onCue?(cue, level)
    }

    /// Links and controls have their own switches.
    private func wants(_ cue: Cue) -> Bool {
        cue == .actionable ? options.links : options.controls
    }

    private func isOwnUI(_ point: CGPoint) -> Bool {
        isPaused || isOwnWindow(point)
    }

    // MARK: - Pointer

    private func pointerMoved(to point: CGPoint) {
        guard !isExcluded, !isOwnUI(point) else { return }
        worker.hover(at: point)
    }

    /// Mouse down. Native lists select on press, so this is what tells a
    /// clicked selection apart from autocomplete.
    private func pressed(at point: CGPoint) {
        lastClick = CACurrentMediaTime()
        // Pressing the control Pulse just cued for: the click itself is felt.
        if memory.contains(point) { quietAfterClickUntil = lastClick + 0.5 }
        worker.invalidateContext() // Windows come forward on press.
    }

    private func clicked(at point: CGPoint) {
        lastClick = CACurrentMediaTime()
        worker.invalidateContext() // Menus open, pages navigate.
        // The clicked control often re-renders with a new identity; a small box
        // at the click keeps it quiet while new UI around it (a menu) still cues.
        memory.remember(CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
    }

    private func handleHover(_ hit: HoverHit?, at point: CGPoint) {
        guard running, !isExcluded else { return }
        guard let hit else {
            // A transient failure inside the cued control is not an exit.
            if memory.contains(point) { return }
            memory.reset()
            lastElement = nil
            pointer.skipRegion = Self.jitterBox(point)
            return
        }

        if hit.kind != nil, let frame = hit.frame {
            pointer.skipRegion = frame // Nothing deeper to find inside a control.
        } else {
            pointer.skipRegion = Self.jitterBox(point)
        }
        // A background window of an app the user turned Pulse off in.
        if !excludedApps.isEmpty, isExcludedApp(AX.pid(hit.element.element)) {
            lastElement = nil
            return
        }

        if lastElement == hit.element { return }
        lastElement = hit.element
        if memory.absorbs(frame: hit.frame, isClickable: hit.kind != nil, at: point) { return }
        if !memory.contains(point) { memory.reset() }

        guard let kind = hit.kind, let frame = hit.frame else { return }
        memory.remember(frame)

        // Content scrolled under a still pointer: remember it silently.
        let passive = CACurrentMediaTime() - lastScroll < Self.scrollSettle
        guard !passive, hit.enabled else { return }
        if hit.caution && options.cautions {
            play(.caution)
        } else if let cue = ControlCueClassifier.cue(for: kind), wants(cue) {
            play(cue)
        }
    }

    // MARK: - Focus, selection, alerts

    /// Windows may have changed without a click (a Space switch).
    func windowsChanged() {
        worker.invalidateContext()
    }

    private func focusChanged(_ ref: AXRef) {
        // Focus moving (Ctrl-Tab, Cmd-`) can change what's under the pointer.
        worker.invalidateContext()
        guard !isExcluded, !isPaused, options.links || options.controls || options.cautions || options.navigation else { return }
        // Focus that follows a click is already felt through hover.
        let followsClick = CACurrentMediaTime() - lastClick < 0.4
        worker.inspectFocus(ref) { [weak self] finding in
            guard let self, self.running, !self.isExcluded, let finding else { return }
            self.focusInTextEntry = finding.isTextEntry
            guard let kind = finding.kind else { return }
            if finding.caution, self.options.cautions, kind == .field {
                self.play(.caution)
                return
            }
            guard kind.isActionable, !followsClick else { return }
            if let frame = finding.frame {
                if self.memory.absorbs(frame: frame, isClickable: true, at: CGPoint(x: frame.midX, y: frame.midY)) { return }
                self.memory.remember(frame)
            }
            if finding.caution && self.options.cautions {
                self.play(.caution)
            } else if let cue = ControlCueClassifier.cue(for: kind), self.wants(cue) {
                self.play(cue)
            }
        }
    }

    /// While typing in a field, a list changing selection is autocomplete,
    /// not navigation, unless a click just picked it. Chat apps keep focus
    /// in the composer while you click through the sidebar.
    private var selectionIsAutocomplete: Bool {
        focusInTextEntry && CACurrentMediaTime() - lastClick > 0.5
    }

    private func selectionChanged(_ ref: AXRef) {
        // One inspection in flight at a time: lists can post selection
        // changes in bursts.
        guard options.navigation, !isExcluded, !isPaused, !selectionIsAutocomplete, !selectionCheckPending else { return }
        selectionCheckPending = true
        worker.inspectSelection(ref) { [weak self] isNavigation in
            guard let self else { return }
            self.selectionCheckPending = false
            guard isNavigation, self.running, !self.isExcluded, !self.selectionIsAutocomplete else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastNavigationCue >= 0.12 else { return }
            self.lastNavigationCue = now
            self.play(.navigation)
        }
    }

    /// A browser's find bar moved to a match: Safari selects it in the page,
    /// Chromium announces its count.
    private func findSignal(_ ref: AXRef, _ signal: FindSignal) {
        guard options.waypoints, !isExcluded, !isPaused else { return }
        let now = CACurrentMediaTime()
        guard now - lastFindMatch >= 0.15 else { return }
        worker.inspectFindSignal(ref, signal) { [weak self] isMatch in
            guard let self, isMatch, self.running, !self.isExcluded, self.options.waypoints else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastFindMatch >= 0.15 else { return }
            self.lastFindMatch = now
            self.play(.waypoint)
        }
    }

    private func liveRegionChanged(_ ref: AXRef) {
        guard options.cautions, !isExcluded, !isPaused else { return }
        // Chat and ticker pages update live regions constantly; only alerts
        // count, at most one cue every two seconds, and at most two checks a
        // second so a busy page can't keep the Accessibility queue full.
        let now = CACurrentMediaTime()
        guard now - lastAlertCue >= 2, now - lastLiveRegionCheck >= 0.5 else { return }
        lastLiveRegionCheck = now
        worker.inspectLiveRegion(ref) { [weak self] isAlert in
            guard let self, isAlert, self.running, !self.isExcluded else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastAlertCue >= 2 else { return }
            self.lastAlertCue = now
            self.play(.caution)
        }
    }

    // MARK: - Scrolling

    private func scrolled(_ event: ScrollEvent) {
        let gap = event.time - lastScroll
        lastScroll = event.time
        worker.invalidate() // Content is moving under the pointer.
        guard !isExcluded, !isOwnUI(event.location) else { return }
        if options.motion { moveMotion(event) }
        // Horizontal-only movement says nothing about vertical ends or
        // headings; probing for it could pair stale direction with an edge.
        guard let direction = event.direction else { return }
        scrollDirection = direction
        // Trackpads mark a new gesture; wheel notches start one after a pause.
        if event.beginsGesture || (event.isDiscrete && gap > 0.35) {
            newGesturePending = true
        }
        scrollPoint = event.location
        guard options.headings || options.boundaries || options.waypoints else { return }

        if event.time - lastProbe >= Self.probeInterval {
            probe()
        }
        // A trailing probe lands the final position: where momentum stopped.
        let fireDate = Date(timeIntervalSinceNow: Self.probeInterval + 0.05)
        if let probeTimer, probeTimer.isValid {
            probeTimer.fireDate = fireDate
            return
        }
        // Parked at distantFuture between gestures, so it's created once.
        let timer = Timer(fire: fireDate, interval: 1e9, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.probeTimer?.fireDate = .distantFuture
                self?.probe()
                self?.settleHoverAfterScroll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    /// Precision and motion scrolling, from speed alone.
    private func moveMotion(_ event: ScrollEvent) {
        if event.beginsGesture { motion.newGesture() }
        guard let pulse = motion.update(delta: event.deltaY, time: event.eventTime) else { return }
        let feel = options.motionHaptics && event.isTouching
        // The model runs either way, so the one that stays on keeps its timing.
        switch pulse {
        case .swell: if options.swell { play(.swell, feel: feel) }
        case let .glide(level): if options.glide { play(.glide, feel: feel, level: Float(level)) }
        }
    }

    private func probe() {
        // The trailing probe can fire after Pulse's menu opened over the page.
        guard let point = scrollPoint, running, !isExcluded, !isOwnUI(point) else { return }
        lastProbe = CACurrentMediaTime()
        worker.probeScroll(at: point)
    }

    /// After scrolling, re-resolve under the still pointer so whatever control
    /// scrolled beneath it is remembered silently rather than ticking on the
    /// next small nudge.
    private func settleHoverAfterScroll() {
        guard options.links || options.controls || options.cautions,
              let point = CGEvent(source: nil)?.location, !isOwnUI(point), !isExcluded
        else { return }
        pointer.skipRegion = nil
        worker.hover(at: point)
    }

    private func handleProbe(_ probe: ScrollProbe) {
        guard running, !isExcluded else { return }
        // Scrolling a background window of an excluded app.
        if !excludedApps.isEmpty, isExcludedApp(probe.pid) { return }
        awareness[probe.pid] = probe.pageAware ? .pageAware : .motionOnly
        // Counts only, at debug level: what a probe saw, for diagnosing a page.
        log.debug("probe aware=\(probe.pageAware, privacy: .public) headings=\(probe.headings.count, privacy: .public) articles=\(probe.articles.count, privacy: .public) edges=\(probe.edges.map { "\($0.atTop ? "top" : "")\($0.atBottom ? "bottom" : "")" } ?? "none", privacy: .public)")
        if probe.pageID != currentPage {
            currentPage = probe.pageID
            landmarks.reset()
            highlights.reset()
        }
        if probe.regionID != currentRegion {
            // A different scroll area: its ends are its own.
            currentRegion = probe.regionID
            boundaries.reset()
        }
        let now = CACurrentMediaTime()
        // A gesture start belongs to the probe right after it, whatever it finds.
        let isNewGesture = newGesturePending
        newGesturePending = false

        if let edges = probe.edges, let direction = scrollDirection {
            // Nothing left to travel: the rest of this gesture (and its
            // rubber-band bounce) glides no further. Content that fits has
            // no ends to stop at.
            if !(edges.atTop && edges.atBottom), direction == .down ? edges.atBottom : edges.atTop { motion.hold() }
            if options.boundaries,
               boundaries.update(edges: edges, direction: direction, isNewGesture: isNewGesture, now: now) {
                play(.boundary)
                return // One action, one cue.
            }
        }
        if options.waypoints,
           highlights.update(headings: probe.highlights, viewportTop: probe.viewportTop, viewportBottom: probe.viewportBottom, now: now) != nil {
            play(.waypoint)
            return
        }
        // A post or article beginning is a section beginning: the same cue,
        // through the same tracker, so a post and its title cue once.
        if options.headings, probe.pageAware,
           landmarks.update(headings: probe.headings + probe.articles, viewportTop: probe.viewportTop, viewportBottom: probe.viewportBottom, now: now) != nil {
            play(.landmark)
        }
    }

    #if DEBUG
    /// The self-test feeds scroll events here instead of through the tap.
    func simulateScroll(_ event: ScrollEvent) {
        scrolled(event)
    }
    #endif

    /// Minimal hysteresis where nothing clickable resolved.
    private static func jitterBox(_ point: CGPoint) -> CGRect {
        CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
    }
}
