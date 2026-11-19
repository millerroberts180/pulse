import ApplicationServices
import Foundation
import PulseCore
import QuartzCore

/// What the pointer is over.
nonisolated struct HoverHit: Sendable {
    var element: AXRef
    /// Nil for anything that isn't an actionable, control-sized target.
    var kind: ElementKind?
    var frame: CGRect?
    var enabled: Bool
    /// Destructive control (label checked transiently, never kept).
    var caution: Bool
}

/// What keyboard focus landed on.
nonisolated struct FocusFinding: Sendable {
    var kind: ElementKind?
    var frame: CGRect?
    /// An invalid field or a destructive control.
    var caution: Bool
    /// A text field, search field, or combo box: suggestion lists changing
    /// selection under it are not navigation.
    var isTextEntry = false
}

/// One look at the scrollable region under the pointer.
nonisolated struct ScrollProbe: Sendable {
    var pid: pid_t
    /// Identity of the region being scrolled, so edge state never carries
    /// from one scroll area to another.
    var regionID: Int
    /// Identity of the web document, so trackers reset on navigation.
    var pageID: Int?
    /// The app exposed document structure (a web area that answers searches).
    var pageAware: Bool
    var headings: [HeadingSample]
    /// Posts and articles near the viewport (feed items, cards, comments):
    /// each one's start is a section beginning, like a heading.
    var articles: [HeadingSample] = []
    /// Highlighted text (`<mark>`) near the viewport, where the browser
    /// can search for it (WebKit).
    var highlights: [HeadingSample] = []
    var viewportTop: Double
    var viewportBottom: Double
    var edges: EdgeState?
}

/// Runs every Accessibility query off the main thread, one at a time.
/// Pointer and scroll requests are latest-wins: while one query runs, newer
/// positions replace the pending one, so stale positions are never resolved.
///
/// Queries that would land on Pulse's own process are refused: answering them
/// off the main thread walks AppKit views unsafely.
nonisolated final class AXWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pulse.accessibility", qos: .userInteractive)
    private let systemWide = AXUIElementCreateSystemWide()
    private let ownPID = getpid()
    private let onHover: @MainActor @Sendable (CGPoint, HoverHit?) -> Void
    private let onProbe: @MainActor @Sendable (ScrollProbe) -> Void

    /// Which optional reads are wanted, so disabled cues cost nothing.
    struct Options: Sendable, Equatable {
        var cautions = true
        var headings = true
        var edges = true
        var highlights = false
    }

    private let lock = NSLock()
    private var pendingHover: CGPoint?
    private var pendingProbe: CGPoint?
    private var draining = false
    private var options = Options() // Guarded by `lock`.

    /// Queue-confined: the scrollable region last resolved.
    private var context: ScrollContext?
    /// Queue-confined: the last element that resolved to nothing, so moving
    /// within it costs one message instead of a search. Its ancestors don't
    /// change, and a leaf has no children. For a container, the frames of
    /// its first children are kept: only entering one of them (lazy
    /// hit-testing can hide a control there) warrants searching again.
    private var inert: InertEntry?
    private struct InertEntry {
        var element: AXRef
        var until: CFTimeInterval
        /// Nil for a leaf.
        var childFrames: [CGRect]?
    }
    /// Bumped by `invalidate()` when content moves (scroll, click).
    private var generation = 0 // Guarded by `lock`.
    private var cachedGeneration = 0 // Queue-confined.
    /// Bumped by `invalidateContext()` when windows may have changed (app
    /// switch, click), so a cached scroll region is never trusted across it.
    private var contextGeneration = 0 // Guarded by `lock`.
    private var cachedContextGeneration = 0 // Queue-confined.
    /// While Pulse's own menu is open, no hit-test may run: one landing on
    /// Pulse's own windows would walk AppKit off the main thread.
    private var paused = false // Guarded by `lock`.
    /// Queue-confined: an app stopped answering; give it a moment.
    private var backoffUntil: CFTimeInterval = 0
    /// Queue-confined: where the pointer was last seen during a backoff, and
    /// whether a retry for it is already scheduled.
    private var backoffPoint: CGPoint?
    private var retryScheduled = false

    /// Extra wall-clock budget for recovering a control from a container.
    private static let searchBudget: CFTimeInterval = 0.03

    init(
        onHover: @escaping @MainActor @Sendable (CGPoint, HoverHit?) -> Void,
        onProbe: @escaping @MainActor @Sendable (ScrollProbe) -> Void
    ) {
        self.onHover = onHover
        self.onProbe = onProbe
        AXUIElementSetMessagingTimeout(systemWide, AX.timeout)
    }

    // MARK: - Requests (any thread)

    func hover(at point: CGPoint) {
        lock.withLock { pendingHover = point }
        kick()
    }

    /// Probes whatever scrollable region is under the point. macOS scrolls the
    /// window under the pointer, which need not belong to the frontmost app.
    func probeScroll(at point: CGPoint) {
        lock.withLock { pendingProbe = point }
        kick()
    }

    func configure(_ newOptions: Options) {
        lock.withLock { options = newOptions }
    }

    /// Content under the pointer moved or changed: forget cached geometry.
    func invalidate() {
        lock.withLock { generation &+= 1 }
    }

    /// Windows may have changed: forget the cached scroll region too.
    func invalidateContext() {
        lock.withLock {
            generation &+= 1
            contextGeneration &+= 1
        }
    }

    /// Main thread, before Pulse's menu appears and after it closes.
    func setPaused(_ isPaused: Bool) {
        lock.withLock { paused = isPaused }
    }

    private var isPaused: Bool { lock.withLock { paused } }

    func inspectFocus(_ ref: AXRef, completion: @escaping @MainActor @Sendable (FocusFinding?) -> Void) {
        queue.async { [self] in
            let finding = describeFocus(ref.element)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(finding) } }
        }
    }

    /// What already has keyboard focus in an app that just became active
    /// (activation posts no focus notification).
    func inspectFocusedElement(ofApp pid: pid_t, completion: @escaping @MainActor @Sendable (FocusFinding?) -> Void) {
        queue.async { [self] in
            var finding: FocusFinding?
            if pid != ownPID {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, AX.timeout)
                if let focused = AX.element(AX.attribute(app, "AXFocusedUIElement")) {
                    finding = describeFocus(focused)
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(finding) } }
        }
    }

    /// Whether a selection change happened in a navigation container.
    func inspectSelection(_ ref: AXRef, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let isNavigation = AX.pid(ref.element) != ownPID
                && ElementClassifier.navigationContainerRoles.contains(AX.info(ref.element).role)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(isNavigation) } }
        }
    }

    /// Whether a live-region update is an alert (role="alert"), the usual way
    /// web forms announce validation errors.
    func inspectLiveRegion(_ ref: AXRef, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let isAlert = AX.pid(ref.element) != ownPID && isAlertRegion(ref.element)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(isAlert) } }
        }
    }

    /// Whether a find-bar signal means the page moved to a match: the
    /// browser's own find field (not one inside a page) has keyboard focus,
    /// and Safari's selection moved within the page itself.
    func inspectFindSignal(_ ref: AXRef, _ signal: FindSignal, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let pid = AX.pid(ref.element)
            var isMatch = false
            if pid != ownPID {
                AXUIElementSetMessagingTimeout(ref.element, AX.timeout)
                switch signal {
                case .selection:
                    isMatch = AX.string(AX.attribute(ref.element, "AXRole")) == "AXWebArea" && findFieldHasFocus(pid: pid)
                case let .announcement(hasMatch):
                    isMatch = hasMatch && findFieldHasFocus(pid: pid)
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(isMatch) } }
        }
    }

    private func findFieldHasFocus(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AX.timeout)
        guard let focused = AX.element(AX.attribute(app, "AXFocusedUIElement")) else { return false }
        let values = AX.attributes(focused, ["AXRole", "AXParent"])
        guard ["AXTextField", "AXComboBox", "AXSearchField"].contains(AX.string(values[0]) ?? "") else { return false }
        // A field inside a web area belongs to the page (or to an Electron
        // app's own UI), not to the browser's find bar.
        var current = AX.element(values[1])
        for _ in 0..<20 {
            guard let element = current else { return true }
            let values = AX.attributes(element, ["AXRole", "AXParent"])
            switch AX.string(values[0]) {
            case "AXWebArea": return false
            case "AXWindow", "AXApplication": return true
            default: current = AX.element(values[1])
            }
        }
        return false
    }

    // MARK: - Drain

    private func kick() {
        let start = lock.withLock {
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            let next: (hover: CGPoint?, probe: CGPoint?, options: Options, generation: Int, contextGeneration: Int) = lock.withLock {
                defer { pendingHover = nil; pendingProbe = nil }
                if pendingHover == nil, pendingProbe == nil { draining = false }
                return (pendingHover, pendingProbe, options, generation, contextGeneration)
            }
            guard next.hover != nil || next.probe != nil else { return }
            if next.generation != cachedGeneration {
                cachedGeneration = next.generation
                inert = nil
            }
            if next.contextGeneration != cachedContextGeneration {
                cachedContextGeneration = next.contextGeneration
                context = nil
            }
            if let point = next.hover {
                let hit = resolveHover(at: point, cautions: next.options.cautions)
                deliver { [onHover] in onHover(point, hit) }
            }
            if let point = next.probe, let probe = probe(at: point, options: next.options) {
                deliver { [onProbe] in onProbe(probe) }
            }
        }
    }

    /// Strict FIFO delivery: a stale result must never overtake a newer one.
    private func deliver(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }

    // MARK: - Hover

    private func resolveHover(at point: CGPoint, cautions: Bool) -> HoverHit? {
        guard !isPaused else { return nil }
        let now = CACurrentMediaTime()
        guard now >= backoffUntil else {
            retryAfterBackoff(point)
            return nil
        }
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitElement)
        if result == .cannotComplete {
            // The app under the pointer is busy or hung: stop asking for a bit.
            backoffUntil = now + 0.5
            retryAfterBackoff(point)
            return nil
        }
        guard result == .success, let element = hitElement, AX.pid(element) != ownPID else { return nil }
        AXUIElementSetMessagingTimeout(element, AX.timeout)

        // Still on the element that resolved to nothing: same answer, unless
        // the pointer entered one of a container's children.
        let ref = AXRef(element)
        if let inert, inert.element == ref, now < inert.until,
           !(inert.childFrames ?? []).contains(where: { $0.contains(point) }) {
            return HoverHit(element: ref, kind: nil, frame: nil, enabled: true, caution: false)
        }

        let info = AX.info(element)
        // The recovery budget starts once the element itself is known.
        let deadline = CACurrentMediaTime() + Self.searchBudget
        var childFrames: [CGRect]?
        let hit = resolve(element, info, at: point, cautions: cautions, deadline: deadline, childFrames: &childFrames)
        // Cache "no control here" only from a search that ran to completion;
        // one cut short by the budget (or a slow app) may have missed it.
        let complete = CACurrentMediaTime() < deadline
        if hit.kind == nil, complete {
            let isLeaf = ElementClassifier.decorativeRoles.contains(info.role)
            // A container is cacheable only if its children were all looked at.
            inert = isLeaf || childFrames != nil ? InertEntry(element: ref, until: now + 1, childFrames: isLeaf ? nil : childFrames) : nil
        } else {
            inert = nil
        }
        return hit
    }

    /// A pointer that came to rest during a backoff would otherwise never be
    /// resolved: no further movement means no further samples. One retry per
    /// backoff, for the latest position seen during it.
    private func retryAfterBackoff(_ point: CGPoint) {
        backoffPoint = point
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = max(backoffUntil - CACurrentMediaTime(), 0) + 0.01
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            retryScheduled = false
            guard let point = backoffPoint, !isPaused else { return }
            backoffPoint = nil
            let queued = lock.withLock {
                guard pendingHover == nil else { return false }
                pendingHover = point
                return true
            }
            if queued { kick() }
        }
    }

    private func resolve(
        _ element: AXUIElement, _ info: AXInfo, at point: CGPoint, cautions: Bool,
        deadline: CFTimeInterval, childFrames: inout [CGRect]?
    ) -> HoverHit {
        let makeHit = { (element: AXUIElement, info: AXInfo, kind: ElementKind) in
            self.makeHit(element, info, kind, cautions: cautions)
        }

        if let kind = clickableKind(element, info) {
            // A generic pressable is either a wrapper holding the real control
            // or a fragment (a text run, an icon) of one. Prefer the real one.
            if kind == .otherClickable {
                if let frame = info.frame, ElementClassifier.isLikelyWrapper(frame),
                   let inner = specificDescendant(of: element, containing: point, depth: 3, deadline: deadline) {
                    return makeHit(inner.element, inner.info, inner.kind)
                }
                if let owner = specificAncestor(of: element, containing: point, deadline: deadline),
                   let frame = owner.info.frame, ElementClassifier.isControlSized(frame) {
                    return makeHit(owner.element, owner.info, owner.kind)
                }
            }
            return makeHit(element, info, kind)
        }
        // The deepest element is often decoration inside the control.
        if let owner = clickableAncestor(of: element, containing: point, deadline: deadline) {
            return makeHit(owner.element, owner.info, owner.kind)
        }
        // Lazy hit-testing: padding reports the group around the control.
        // The first level is fetched here so its frames can be cached.
        let children = AX.children(element, limit: 12)
        var frames: [CGRect] = []
        for child in children {
            guard CACurrentMediaTime() < deadline else { return HoverHit(element: AXRef(element), kind: nil, frame: info.frame, enabled: info.enabled, caution: false) }
            let childInfo = AX.info(child)
            guard let frame = childInfo.frame else { continue }
            frames.append(frame)
            guard frame.contains(point) else { continue }
            if let kind = clickableKind(child, childInfo) { return makeHit(child, childInfo, kind) }
            if let deeper = clickableDescendant(of: child, containing: point, depth: 1, deadline: deadline) {
                return makeHit(deeper.element, deeper.info, deeper.kind)
            }
        }
        childFrames = frames
        return HoverHit(element: AXRef(element), kind: nil, frame: info.frame, enabled: info.enabled, caution: false)
    }

    private struct Candidate {
        var element: AXUIElement
        var info: AXInfo
        var kind: ElementKind
    }

    /// The actionable kind of an element, asking for actions only when its
    /// role leaves the question open.
    private func clickableKind(_ element: AXUIElement, _ info: AXInfo) -> ElementKind? {
        if let kind = ElementClassifier.kind(role: info.role, subrole: info.subrole) {
            return kind.isActionable ? kind : nil
        }
        guard !ElementClassifier.decorativeRoles.contains(info.role),
              !ElementClassifier.structuralRoles.contains(info.role),
              ElementClassifier.isPressable(actions: AX.actions(element))
        else { return nil }
        return .otherClickable
    }

    private func makeHit(_ element: AXUIElement, _ info: AXInfo, _ kind: ElementKind, cautions: Bool) -> HoverHit {
        // Window-sized "controls" are containers; treating one as a target
        // would cue once and then silence the whole window.
        guard let frame = info.frame, ElementClassifier.isControlSized(frame) else {
            return HoverHit(element: AXRef(element), kind: nil, frame: info.frame, enabled: info.enabled, caution: false)
        }
        return HoverHit(
            element: AXRef(element),
            kind: kind,
            frame: frame,
            enabled: info.enabled,
            caution: cautions && isCautionary(element, info, kind)
        )
    }

    /// Reads the label only to check for a destructive word; it never leaves
    /// this function.
    private func isCautionary(_ element: AXUIElement, _ info: AXInfo, _ kind: ElementKind) -> Bool {
        if info.subrole == "AXCloseButton" { return true }
        guard kind == .button || kind == .menuItem || kind == .toggle || kind == .otherClickable else { return false }
        let labels = AX.attributes(element, ["AXTitle", "AXDescription"])
        let label = [AX.string(labels[0]), AX.string(labels[1])].compactMap { $0 }.first { !$0.isEmpty }
        return CautionDetector.isDestructive(kind: kind, subrole: info.subrole, label: label)
    }

    private func clickableAncestor(of element: AXUIElement, containing point: CGPoint, deadline: CFTimeInterval) -> Candidate? {
        var current = element
        for _ in 0..<3 {
            guard CACurrentMediaTime() < deadline, let parent = AX.parent(current) else { return nil }
            let info = AX.info(parent)
            if ElementClassifier.structuralRoles.contains(info.role) { return nil }
            if let kind = clickableKind(parent, info), info.frame?.contains(point) == true {
                return Candidate(element: parent, info: info, kind: kind)
            }
            current = parent
        }
        return nil
    }

    /// Walks up to an unambiguous control (not another generic pressable).
    private func specificAncestor(of element: AXUIElement, containing point: CGPoint, deadline: CFTimeInterval) -> Candidate? {
        var current = element
        for _ in 0..<4 {
            guard CACurrentMediaTime() < deadline, let parent = AX.parent(current) else { return nil }
            let info = AX.info(parent)
            if ElementClassifier.structuralRoles.contains(info.role) { return nil }
            if let kind = ElementClassifier.kind(role: info.role, subrole: info.subrole), kind.isActionable,
               info.frame?.contains(point) == true {
                return Candidate(element: parent, info: info, kind: kind)
            }
            current = parent
        }
        return nil
    }

    /// Spatial descent: only children containing the point, so it stays a
    /// narrow path rather than a tree walk.
    private func clickableDescendant(of element: AXUIElement, containing point: CGPoint, depth: Int, deadline: CFTimeInterval) -> Candidate? {
        guard depth > 0 else { return nil }
        for child in AX.children(element, limit: 12) {
            guard CACurrentMediaTime() < deadline else { return nil }
            let info = AX.info(child)
            guard info.frame?.contains(point) == true else { continue }
            if let kind = clickableKind(child, info) { return Candidate(element: child, info: info, kind: kind) }
            if let deeper = clickableDescendant(of: child, containing: point, depth: depth - 1, deadline: deadline) {
                return deeper
            }
        }
        return nil
    }

    private func specificDescendant(of element: AXUIElement, containing point: CGPoint, depth: Int, deadline: CFTimeInterval) -> Candidate? {
        guard depth > 0 else { return nil }
        for child in AX.children(element, limit: 12) {
            guard CACurrentMediaTime() < deadline else { return nil }
            let info = AX.info(child)
            guard info.frame?.contains(point) == true else { continue }
            if let kind = ElementClassifier.kind(role: info.role, subrole: info.subrole), kind.isActionable {
                return Candidate(element: child, info: info, kind: kind)
            }
            if let deeper = specificDescendant(of: child, containing: point, depth: depth - 1, deadline: deadline) {
                return deeper
            }
        }
        return nil
    }

    // MARK: - Focus and live regions

    private func describeFocus(_ element: AXUIElement) -> FocusFinding? {
        guard AX.pid(element) != ownPID else { return nil }
        AXUIElementSetMessagingTimeout(element, AX.timeout)
        let info = AX.info(element)
        let isTextEntry = info.role == "AXTextField" || info.role == "AXTextArea" || info.role == "AXComboBox"
            || info.subrole == "AXSearchField"
        guard let kind = ElementClassifier.kind(role: info.role, subrole: info.subrole)
            ?? (ElementClassifier.isPressable(actions: AX.actions(element)) ? .otherClickable : nil)
        else { return FocusFinding(kind: nil, frame: info.frame, caution: false, isTextEntry: isTextEntry) }

        let caution: Bool
        if kind == .field {
            caution = CautionDetector.isInvalid(AX.string(AX.attribute(element, "AXInvalid")))
        } else {
            caution = isCautionary(element, info, kind)
        }
        return FocusFinding(kind: kind, frame: info.frame, caution: caution, isTextEntry: isTextEntry)
    }

    private func isAlertRegion(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, AX.timeout)
        var current: AXUIElement? = element
        for _ in 0..<3 {
            guard let candidate = current else { return false }
            let subrole = AX.string(AX.attribute(candidate, "AXSubrole"))
            if subrole == "AXApplicationAlert" || subrole == "AXApplicationAlertDialog" { return true }
            current = AX.parent(candidate)
        }
        return false
    }

    // MARK: - Scroll probe

    private struct ScrollContext {
        var pid: pid_t
        /// The nearest scrollable region under the pointer (may be inside the page).
        var scrollArea: AXUIElement?
        var scrollBar: AXUIElement?
        var webArea: AXUIElement?
        /// The page's visible frame, for the reading line.
        var viewport: CGRect
        /// The frame of the region being scrolled (an inner scroller or frame
        /// can be smaller than the page).
        var regionFrame: CGRect
        /// Whether the web area sits inside the scroll area as its document.
        var documentInScrollArea: Bool
        var resolvedAt: CFTimeInterval
        /// Whether this web area answers heading searches; nil until asked.
        var searchable: Bool?
    }

    /// Queue-confined. Apps whose highlight search isn't real: Chromium
    /// answers search keys it doesn't know with every element.
    private var highlightsUnsupported: Set<pid_t> = []
    /// Queue-confined. How each app finds articles: WebKit and Gecko answer
    /// the article search; Chromium doesn't know it (and answers with every
    /// element) but lists articles among its landmarks.
    private enum ArticleSearch { case articleKey, landmarks }
    private var articleSearch: [pid_t: ArticleSearch] = [:]
    /// Queue-confined. Whether a page has any articles, by web area, rechecked
    /// every few seconds, so pages without them aren't searched on every probe.
    private var articlePresence: [Int: (present: Bool, checked: CFTimeInterval)] = [:]
    /// Queue-confined. Whether a page has any highlights at all, by web area,
    /// rechecked every few seconds. A search for something a page doesn't
    /// have walks the whole document, so it isn't repeated on every probe.
    private var highlightPresence: [Int: (present: Bool, checked: CFTimeInterval)] = [:]

    private func probe(at point: CGPoint, options: Options) -> ScrollProbe? {
        guard !isPaused else { return nil }
        let now = CACurrentMediaTime()
        guard now >= backoffUntil else { return nil }
        // Still inside the region resolved a moment ago, and no window change
        // since (app switches and clicks clear it): no hit-test needed.
        if let cached = context, cached.regionFrame.contains(point), now - cached.resolvedAt < 1 {
            if let probe = read(cached, options: options) { return probe }
        }
        guard let hit = AX.element(at: point, in: systemWide) else { return nil }
        let pid = AX.pid(hit)
        guard pid != ownPID else { return nil }
        context = resolveContext(from: hit, pid: pid, now: now)
        guard let resolved = context else { return nil }
        return read(resolved, options: options)
    }

    private func resolveContext(from hit: AXUIElement, pid: pid_t, now: CFTimeInterval) -> ScrollContext? {

        var scrollArea: AXUIElement?
        var webArea: AXUIElement?
        var outerScrollArea: AXUIElement?
        var current: AXUIElement? = hit
        for _ in 0..<40 {
            guard let element = current else { break }
            let values = AX.attributes(element, ["AXRole", "AXParent"])
            let role = AX.string(values[0])
            if role == "AXWindow" || role == "AXApplication" { break }
            if role == "AXWebArea", webArea == nil { webArea = element }
            if role == "AXScrollArea" {
                if scrollArea == nil { scrollArea = element }
                if webArea != nil { outerScrollArea = element; break }
            }
            current = AX.element(values[1])
        }
        guard scrollArea != nil || webArea != nil else { return nil }

        let viewportElement = outerScrollArea ?? webArea ?? scrollArea
        guard let viewportElement, let viewport = AX.frame(viewportElement) else { return nil }
        // Frames only describe the page's ends when the region being scrolled
        // is the one holding the document.
        var documentInScrollArea = false
        if let outerScrollArea, let scrollArea { documentInScrollArea = CFEqual(outerScrollArea, scrollArea) }
        let regionFrame = documentInScrollArea ? viewport : (scrollArea.flatMap(AX.frame) ?? viewport)
        return ScrollContext(
            pid: pid,
            scrollArea: scrollArea,
            scrollBar: scrollArea.flatMap { AX.element(AX.attribute($0, "AXVerticalScrollBar")) },
            webArea: webArea,
            viewport: viewport,
            regionFrame: regionFrame,
            documentInScrollArea: documentInScrollArea,
            resolvedAt: now
        )
    }

    private func read(_ context: ScrollContext, options: Options) -> ScrollProbe? {
        let edges = options.edges ? readEdges(context) : nil
        var headings: [HeadingSample] = []
        var articles: [HeadingSample] = []
        var pageAware = false
        if let webArea = context.webArea, context.searchable != false {
            if options.headings {
                if let found = visibleHeadings(in: webArea, viewport: context.viewport) {
                    headings = found
                    articles = visibleArticles(in: webArea, viewport: context.viewport, pid: context.pid)
                    pageAware = true
                    self.context?.searchable = true
                } else if AX.attribute(webArea, "AXRole") == nil {
                    // The page went away (navigation): resolve again next time.
                    self.context = nil
                    return nil
                } else {
                    // A live web area that doesn't answer searches: Motion-only.
                    self.context?.searchable = false
                }
            } else if let searchable = context.searchable {
                pageAware = searchable
            } else {
                // Headings are off, but the status line still wants to know.
                let answers = AX.search(in: webArea, key: "AXHeadingSearchKey", from: nil, forward: true, limit: 1, visibleOnly: false) != nil
                self.context?.searchable = answers
                pageAware = answers
            }
        }
        var highlights: [HeadingSample] = []
        if options.highlights, let webArea = context.webArea, !highlightsUnsupported.contains(context.pid) {
            highlights = visibleHighlights(in: webArea, viewport: context.viewport, pid: context.pid)
        }
        let region = context.scrollArea ?? context.webArea
        return ScrollProbe(
            pid: context.pid,
            regionID: region.map { Int(bitPattern: UInt(CFHash($0))) } ?? 0,
            pageID: context.webArea.map { Int(bitPattern: UInt(CFHash($0))) },
            pageAware: pageAware,
            headings: headings,
            articles: articles,
            highlights: highlights,
            viewportTop: Double(context.viewport.minY),
            viewportBottom: Double(context.viewport.maxY),
            edges: edges
        )
    }

    private func readEdges(_ context: ScrollContext) -> EdgeState? {
        if let bar = context.scrollBar, let value = AX.number(AX.attribute(bar, "AXValue")) {
            return EdgeState(scrollBarValue: value)
        }
        // A document inside its viewport: compare frames.
        if context.documentInScrollArea, let webArea = context.webArea, var document = AX.frame(webArea) {
            let viewport = context.viewport
            if abs(document.minY - viewport.minY) < 2, abs(document.height - viewport.height) < 2 {
                // Gecko (Firefox, Zen) reports the web area at the viewport's
                // size, which would read as "fits, at both ends". Its content
                // knows the document's real extent.
                guard let content = contentExtent(of: webArea) else { return nil }
                document = content
            }
            return EdgeState(
                documentTop: Double(document.minY), documentBottom: Double(document.maxY),
                viewportTop: Double(viewport.minY), viewportBottom: Double(viewport.maxY)
            )
        }
        return nil
    }

    /// The span from the top of a web area's first children to the bottom of
    /// its last ones (often a single group: the page body). Several at each
    /// end, so a fixed banner or an empty overlay container can't stand in
    /// for the end of the page.
    private func contentExtent(of webArea: AXUIElement) -> CGRect? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(webArea, "AXChildren" as CFString, &count) == .success, count > 0 else { return nil }
        let take = min(count, 3)
        var tail: CFArray?
        let first = AX.children(webArea, limit: take)
        let last: [AXUIElement] = if count > take,
            AXUIElementCopyAttributeValues(webArea, "AXChildren" as CFString, count - take, take, &tail) == .success {
            (tail as? [AXUIElement]) ?? []
        } else { first }
        for element in last { AXUIElementSetMessagingTimeout(element, AX.timeout) }
        let firstFrames = first.compactMap(AX.frame).filter { $0.height > 0 }
        let lastFrames = last.compactMap(AX.frame).filter { $0.height > 0 }
        guard let top = firstFrames.map(\.minY).min(), let bottom = lastFrames.map(\.maxY).max(), bottom > top else { return nil }
        return CGRect(x: 0, y: top, width: 1, height: bottom - top)
    }

    /// Headings around the viewport: the two before the element 15 % down
    /// (below most sticky headers, above the reading line) and up to ten
    /// after it, cut off a viewport below. Searches stay bounded by their
    /// result limits; a visible-only filter would make the browser walk the
    /// whole document whenever fewer headings are visible than the limit,
    /// and would drop the headings just outside the viewport that crossing
    /// detection needs.
    private func visibleHeadings(in webArea: AXUIElement, viewport: CGRect) -> [HeadingSample]? {
        guard !isPaused else { return nil }
        let probePoint = CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * 0.15)
        // Hit-test inside the browser itself, so a window of another app
        // covering that spot doesn't hide the page. (Never Pulse's process:
        // web areas belong to other apps.)
        let browser = AXUIElementCreateApplication(AX.pid(webArea))
        AXUIElementSetMessagingTimeout(browser, AX.timeout)
        let start = AX.element(at: probePoint, in: browser)

        guard let below = AX.search(in: webArea, key: "AXHeadingSearchKey", from: start, forward: true, limit: 10, visibleOnly: false)
        else { return nil }
        let above = start == nil ? [] : (AX.search(in: webArea, key: "AXHeadingSearchKey", from: start, forward: false, limit: 2, visibleOnly: false) ?? [])

        let horizon = viewport.maxY + viewport.height
        var samples: [HeadingSample] = []
        for heading in above + below {
            let values = AX.attributes(heading, ["AXPosition", "AXSize", "AXValue"])
            guard let origin = AX.point(values[0]), let size = AX.size(values[1]), size.height > 0 else { continue }
            if origin.y > horizon { break }
            samples.append(HeadingSample(
                id: Int(bitPattern: UInt(CFHash(heading))),
                level: AX.number(values[2]).map { Int($0) },
                top: Double(origin.y)
            ))
        }
        return samples
    }

    /// Highlighted runs around the viewport, like `visibleHeadings`. A real
    /// answer holds only text runs and the groups around them, never the page
    /// itself or a heading, link, or control; anything else marks the app's
    /// search as unsupported.
    private func visibleHighlights(in webArea: AXUIElement, viewport: CGRect, pid: pid_t) -> [HeadingSample] {
        guard !isPaused else { return [] }
        let isHighlight = { (role: String?) in role == "AXStaticText" || role == "AXGroup" }
        let page = Int(bitPattern: UInt(CFHash(webArea)))
        let now = CACurrentMediaTime()
        if let known = highlightPresence[page], now - known.checked < 5 {
            guard known.present else { return [] }
        } else {
            guard let first = AX.search(in: webArea, key: "AXHighlightedSearchKey", from: nil, forward: true, limit: 1, visibleOnly: false) else {
                highlightsUnsupported.insert(pid)
                return []
            }
            if let element = first.first, !isHighlight(AX.string(AX.attribute(element, "AXRole"))) {
                highlightsUnsupported.insert(pid)
                return []
            }
            if highlightPresence.count > 32 { highlightPresence.removeAll() }
            highlightPresence[page] = (!first.isEmpty, now)
            guard !first.isEmpty else { return [] }
        }
        let probePoint = CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * 0.15)
        let browser = AXUIElementCreateApplication(AX.pid(webArea))
        AXUIElementSetMessagingTimeout(browser, AX.timeout)
        let start = AX.element(at: probePoint, in: browser)
        guard let below = AX.search(in: webArea, key: "AXHighlightedSearchKey", from: start, forward: true, limit: 8, visibleOnly: false)
        else { return [] }
        let above = start == nil ? [] : (AX.search(in: webArea, key: "AXHighlightedSearchKey", from: start, forward: false, limit: 2, visibleOnly: false) ?? [])

        let horizon = viewport.maxY + viewport.height
        var samples: [HeadingSample] = []
        for element in above + below {
            let values = AX.attributes(element, ["AXRole", "AXPosition", "AXSize"])
            guard isHighlight(AX.string(values[0])) else {
                highlightsUnsupported.insert(pid)
                return []
            }
            guard let origin = AX.point(values[1]), let size = AX.size(values[2]), size.height > 0 else { continue }
            if origin.y > horizon { break }
            // WebKit reports a mark and its text run: one waypoint.
            if samples.contains(where: { abs($0.top - Double(origin.y)) < 2 }) { continue }
            samples.append(HeadingSample(id: Int(bitPattern: UInt(CFHash(element))), level: nil, top: Double(origin.y)))
        }
        return samples
    }

    /// Posts and articles around the viewport, like `visibleHeadings`: the
    /// two before the point 15 % down and up to six after it. Only real
    /// article groups count, whatever the search answers.
    private func visibleArticles(in webArea: AXUIElement, viewport: CGRect, pid: pid_t) -> [HeadingSample] {
        guard !isPaused else { return [] }
        let isArticle = { (element: AXUIElement) -> Bool in
            AX.string(AX.attribute(element, "AXSubrole")) == "AXDocumentArticle"
        }
        let page = Int(bitPattern: UInt(CFHash(webArea)))
        let now = CACurrentMediaTime()
        if articleSearch[pid] == nil {
            // Which search does this app really answer?
            let first = AX.search(in: webArea, key: "AXArticleSearchKey", from: nil, forward: true, limit: 1, visibleOnly: false)
            if let element = first?.first {
                articleSearch[pid] = isArticle(element) ? .articleKey : .landmarks
            } else if first != nil {
                // Nothing found; this page may simply have none. Decide on a page that has one.
                articlePresence[page] = (false, now)
                return []
            } else {
                articleSearch[pid] = .landmarks
            }
        }
        let key = articleSearch[pid] == .articleKey ? "AXArticleSearchKey" : "AXLandmarkSearchKey"
        if let known = articlePresence[page], now - known.checked < 5 {
            guard known.present else { return [] }
        } else {
            // Chromium can list dozens of regions before the first article.
            let any = AX.search(in: webArea, key: key, from: nil, forward: true, limit: key == "AXArticleSearchKey" ? 1 : 60, visibleOnly: false) ?? []
            if articlePresence.count > 32 { articlePresence.removeAll() }
            let present = any.contains(where: isArticle)
            articlePresence[page] = (present, now)
            guard present else { return [] }
        }

        let probePoint = CGPoint(x: viewport.midX, y: viewport.minY + viewport.height * 0.15)
        let browser = AXUIElementCreateApplication(AX.pid(webArea))
        AXUIElementSetMessagingTimeout(browser, AX.timeout)
        let start = AX.element(at: probePoint, in: browser)
        let below = AX.search(in: webArea, key: key, from: start, forward: true, limit: 6, visibleOnly: false) ?? []
        let above = start == nil ? [] : (AX.search(in: webArea, key: key, from: start, forward: false, limit: 2, visibleOnly: false) ?? [])
        let horizon = viewport.maxY + viewport.height
        var samples: [HeadingSample] = []
        for element in above + below {
            let values = AX.attributes(element, ["AXSubrole", "AXPosition", "AXSize"])
            guard AX.string(values[0]) == "AXDocumentArticle",
                  let origin = AX.point(values[1]), let size = AX.size(values[2]), size.height > 0
            else { continue }
            if origin.y > horizon { break }
            samples.append(HeadingSample(id: Int(bitPattern: UInt(CFHash(element))), level: 2, top: Double(origin.y)))
        }
        return samples
    }
}
