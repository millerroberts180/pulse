/// How fast scrolling has to get before Pulse responds to it at all.
public enum MotionThreshold: String, Sendable, CaseIterable, Codable {
    /// Responds to brisk scrolling.
    case early
    case standard
    /// Only fast flicks.
    case late

    /// Points per second. Reading line by line rarely passes 300.
    public var speed: Double {
        switch self {
        case .early: 550
        case .standard: 850
        case .late: 1400
        }
    }
}

/// How present the glide is once it starts.
public enum MotionIntensity: String, Sendable, CaseIterable, Codable {
    case subtle, standard, lively

    /// Multiplies the time between glide pulses.
    var spacing: Double {
        switch self {
        case .subtle: 1.35
        case .standard: 1
        case .lively: 0.8
        }
    }

    /// Multiplies the glide sound's level.
    public var soundGain: Float {
        switch self {
        case .subtle: 0.6
        case .standard: 1
        case .lively: 1.35
        }
    }
}

/// Precision and motion scrolling. Slow scrolling is silent. Past a speed
/// threshold a sparse glide begins: its pulses come closer together, and
/// softer, as speed rises, and thin out as the scroll slows until silence
/// returns. A quick burst of acceleration is one soft swell instead.
///
/// Speed is smoothed by a 35 ms exponential follower of |Δ|/Δt; spacing is
/// in time, not distance, so a fling feels like a flywheel rather than a
/// ratchet.
public struct MotionModel: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Points per second where motion begins.
        public var threshold: Double
        /// Motion ends below `threshold × exitRatio`, so hovering near the
        /// threshold doesn't flicker on and off.
        public var exitRatio = 0.7
        /// Time between glide pulses at the threshold, and at full speed.
        public var slowestInterval = 0.13
        public var fastestInterval = 0.07
        /// The first glide after motion begins. A swipe's fingers are down
        /// for only a quarter second or so, and haptics can't be felt once
        /// they lift, so the glide has to start while they're still moving.
        public var firstGlideDelay = 0.06
        /// Full speed, as a multiple of the threshold.
        public var fullSpeedMultiple = 4.0
        /// A swell: speed reaches `threshold × swellLevel` and grew by
        /// `swellGrowth` within `swellWindow`.
        public var swellLevel = 1.8
        public var swellGrowth = 1.6
        public var swellWindow = 0.15
        public var swellCooldown = 0.8
        /// The first glide after a swell waits at least this long, so the
        /// two don't blur into one pulse.
        public var afterSwell = 0.06

        public init(threshold: MotionThreshold = .standard, intensity: MotionIntensity = .standard) {
            self.threshold = threshold.speed
            slowestInterval *= intensity.spacing
            fastestInterval *= intensity.spacing
        }
    }

    public enum Pulse: Sendable, Equatable {
        /// A burst of acceleration.
        case swell
        /// Sustained fast movement. `level` is 1 at the threshold and falls
        /// to 0.6 at full speed: closer pulses are gentler ones.
        case glide(level: Double)
    }

    public var tuning: Tuning

    /// Smoothed speed, points per second.
    public private(set) var speed: Double = 0
    public private(set) var inMotion = false

    private var lastTime: Double?
    private var lastSign: Double = 0
    private var lastPulse: Double = -.infinity
    private var lastSwell: Double = -.infinity
    private var quietUntil: Double = -.infinity
    private var anchorSpeed: Double = 0
    private var anchorTime: Double = -.infinity
    private var held = false

    /// A pause longer than this starts the speed estimate over.
    static let restartGap = 0.15
    static let smoothing = 0.035
    static let maximumSpeed = 8000.0

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Back to precision: a new gesture, or the scroll ended.
    public mutating func reset() {
        speed = 0
        inMotion = false
        lastTime = nil
        lastSign = 0
        anchorSpeed = 0
        anchorTime = -.infinity
        held = false
    }

    /// Fingers came down for another swipe. Speed carries over (repeated
    /// swipes keep a fast scroll going); only a page-end hold is cleared.
    public mutating func newGesture() {
        held = false
    }

    /// Silent until the next gesture: the page ended, and the rest of this
    /// gesture (or its rubber-band bounce) has nowhere to travel.
    public mutating func hold() {
        held = true
        inMotion = false
    }

    /// One vertical scroll step: `delta` in points (either sign), `time` in
    /// seconds on any monotonic clock.
    public mutating func update(delta: Double, time: Double) -> Pulse? {
        guard delta != 0 else { return nil }
        let sign: Double = delta < 0 ? -1 : 1
        // A pause or a change of direction is a fresh start.
        if let lastTime, time - lastTime > Self.restartGap || sign != lastSign {
            speed = 0
            inMotion = false
            anchorSpeed = 0
            anchorTime = time
        }
        let dt = max(time - (lastTime ?? (time - 1.0 / 60.0)), 0.001)
        lastTime = time
        lastSign = sign
        let instantaneous = min(abs(delta) / dt, Self.maximumSpeed)
        speed += (instantaneous - speed) * dt / (dt + Self.smoothing)

        if time - anchorTime > tuning.swellWindow {
            anchorSpeed = speed
            anchorTime = time
        }
        guard !held else { return nil }

        let threshold = tuning.threshold
        if !inMotion {
            guard speed >= threshold else { return nil }
            inMotion = true
            // The first glide waits a beat: motion builds, it doesn't snap on.
            lastPulse = -.infinity
            quietUntil = time + tuning.firstGlideDelay
        } else if speed < threshold * tuning.exitRatio {
            inMotion = false
            return nil
        }

        if speed >= threshold * tuning.swellLevel,
           speed >= max(anchorSpeed, 1) * tuning.swellGrowth,
           time - lastSwell >= tuning.swellCooldown {
            lastSwell = time
            lastPulse = time
            quietUntil = time + tuning.afterSwell
            anchorSpeed = speed // One surge per burst.
            return .swell
        }

        let progress = Self.progress(speed: speed, threshold: threshold, fullSpeed: threshold * tuning.fullSpeedMultiple)
        let interval = tuning.slowestInterval + (tuning.fastestInterval - tuning.slowestInterval) * progress
        guard time - lastPulse >= interval, time >= quietUntil else { return nil }
        lastPulse = time
        return .glide(level: 1 - 0.4 * progress)
    }

    /// 0 at the threshold, 1 at full speed, eased so the change is gradual.
    static func progress(speed: Double, threshold: Double, fullSpeed: Double) -> Double {
        let linear = min(max((speed - threshold) / max(fullSpeed - threshold, 1), 0), 1)
        return linear * linear * (3 - 2 * linear)
    }
}
