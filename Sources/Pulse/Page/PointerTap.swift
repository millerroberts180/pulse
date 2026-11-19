import AppKit
import PulseCore
import QuartzCore

/// One scroll-wheel event, reduced to what the page detector needs.
struct ScrollEvent {
    /// Positive scrolls toward the top of the content.
    var deltaY: Double
    var phase: Int64
    var momentumPhase: Int64
    var location: CGPoint
    var time: CFTimeInterval
    /// When the hardware produced the event, on the same clock as `time`.
    /// Steadier than `time` for measuring speed: events that queue behind
    /// a busy main thread arrive together but keep their own timestamps.
    var eventTime: CFTimeInterval

    var direction: ScrollDirection? {
        deltaY == 0 ? nil : (deltaY < 0 ? .down : .up)
    }

    /// kCGScrollPhaseBegan: fingers just started a new scroll.
    var beginsGesture: Bool { phase == 1 }
    /// Discrete mouse-wheel events carry neither phase.
    var isDiscrete: Bool { phase == 0 && momentumPhase == 0 }
    /// Fingers are on the trackpad: a haptic can be felt.
    var isTouching: Bool { phase != 0 && momentumPhase == 0 }
}

/// Watches pointer movement, scrolling, and clicks system-wide through a
/// listen-only event tap. A tap (not NSEvent monitors) keeps working inside
/// menu tracking loops. When the pointer is still, nothing runs; when no cue
/// needs pointer events (muted, excluded app, cues off), there is no tap.
///
/// Three gates keep Accessibility queries rare without adding felt lag, as in
/// Tactile: a time throttle with a trailing sample (so the resting position
/// always resolves), a 2 px jitter gate, and a skip region covering the control
/// last resolved.
final class PointerTap {
    var onMove: ((CGPoint) -> Void)?
    var onScroll: ((ScrollEvent) -> Void)?
    /// A mouse button went down: native lists select on press.
    var onPress: ((CGPoint) -> Void)?
    /// A mouse button came up.
    var onClick: ((CGPoint) -> Void)?

    var sampleInterval: CFTimeInterval = 1.0 / 60.0
    /// While the pointer stays inside this rect no samples are emitted.
    var skipRegion: CGRect?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mask: CGEventMask = 0
    private var wantsMoves = false
    /// One timer, re-armed by moving its fire date rather than recreated.
    private var trailing: Timer?
    /// Tracked explicitly: a fire date of `.distantFuture` is clamped by the
    /// system, so comparing against it can't tell parked from armed.
    private var isArmed = false
    private var trailingSettles = false
    private var lastSample: CFTimeInterval = 0
    private var lastPoint: CGPoint?
    /// The latest pointer location seen in an event (no query needed).
    private var latestPoint: CGPoint?
    private let jitter: CGFloat = 2

    var isRunning: Bool { tap != nil }

    /// Listens for exactly what's wanted. Drags are left out on purpose:
    /// selecting text or dragging a window must not tick across every link.
    /// Button events are rare, so `clicks` costs next to nothing.
    /// Returns false if the system refused the tap.
    @discardableResult
    func configure(moves: Bool, scrolls: Bool, clicks: Bool) -> Bool {
        wantsMoves = moves
        var types: [CGEventType] = []
        if moves { types.append(.mouseMoved) }
        if moves || clicks { types += [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp] }
        if scrolls { types.append(.scrollWheel) }
        let newMask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard newMask != mask || (newMask != 0 && tap == nil) else { return true }
        stop()
        guard newMask != 0 else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: newMask,
            callback: pointerTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        mask = newMask
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        mask = 0
        trailing?.invalidate()
        trailing = nil
        isArmed = false
        lastPoint = nil
        latestPoint = nil
        skipRegion = nil
    }

    /// Forgets geometry so the next movement resolves fresh (after a click).
    func invalidate() {
        skipRegion = nil
        lastPoint = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .mouseMoved:
            latestPoint = event.location
            moved()
        case .scrollWheel:
            latestPoint = event.location
            onScroll?(ScrollEvent(
                deltaY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                location: event.location,
                time: CACurrentMediaTime(),
                // Nanoseconds of the uptime clock CACurrentMediaTime also reads.
                eventTime: event.timestamp > 0 ? Double(event.timestamp) / 1_000_000_000 : CACurrentMediaTime()
            ))
        case .leftMouseDown, .rightMouseDown:
            onPress?(event.location)
        case .leftMouseUp, .rightMouseUp:
            latestPoint = event.location
            invalidate()
            onClick?(event.location)
            // Clicks change what's under the pointer (menus open, pages
            // navigate): look again once that has landed, even if a sooner
            // sample was pending.
            if wantsMoves { arm(after: 0.15, settling: true, force: true) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    private func moved() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastSample
        if elapsed < sampleInterval {
            arm(after: sampleInterval - elapsed, settling: true)
            return
        }
        sample(now: now, settling: false)
    }

    /// `settling`: the pointer came to rest, so resolve where it is even if
    /// the last nudge was inside the jitter gate.
    private func sample(now: CFTimeInterval, settling: Bool) {
        disarm()
        guard let point = latestPoint else { return }
        if !settling, let lastPoint, hypot(point.x - lastPoint.x, point.y - lastPoint.y) < jitter {
            arm(after: sampleInterval, settling: true)
            return
        }
        lastPoint = point
        if let skipRegion, skipRegion.contains(point) { return }
        lastSample = now
        onMove?(point)
    }

    // MARK: - Trailing sample

    private func arm(after delay: TimeInterval, settling: Bool, force: Bool = false) {
        guard force || !isArmed else { return }
        isArmed = true
        trailingSettles = settling
        let fireDate = Date(timeIntervalSinceNow: max(delay, 0.005))
        if let trailing {
            trailing.fireDate = fireDate
            return
        }
        // Repeating with a far-off interval so it survives firing and can be
        // re-armed; it parks at distantFuture between uses.
        let timer = Timer(fire: fireDate, interval: 1e9, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.disarm()
                self.sample(now: CACurrentMediaTime(), settling: self.trailingSettles)
            }
        }
        // Common modes keep it firing during menu tracking.
        RunLoop.main.add(timer, forMode: .common)
        trailing = timer
    }

    private func disarm() {
        isArmed = false
        trailing?.fireDate = .distantFuture
    }
}

/// The tap's run-loop source lives on the main run loop, so this runs on main.
private nonisolated func pointerTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let tap = Unmanaged<PointerTap>.fromOpaque(userInfo).takeUnretainedValue()
        // Delivered on the main run loop; the event never leaves this call.
        nonisolated(unsafe) let event = event
        MainActor.assumeIsolated { tap.handle(type, event) }
    }
    return Unmanaged.passUnretained(event)
}
