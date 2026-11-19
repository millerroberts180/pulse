import Testing
@testable import PulseCore

/// Drives the model at a trackpad's 120 Hz event rate with a speed profile.
private func drive(
    _ model: inout MotionModel, speeds: [Double], start: Double = 0, sign: Double = -1
) -> [(time: Double, pulse: MotionModel.Pulse)] {
    let dt = 1.0 / 120
    var pulses: [(Double, MotionModel.Pulse)] = []
    for (index, speed) in speeds.enumerated() {
        let time = start + Double(index) * dt
        if let pulse = model.update(delta: sign * speed * dt, time: time) { pulses.append((time, pulse)) }
    }
    return pulses
}

private func ramp(from: Double, to: Double, seconds: Double) -> [Double] {
    let steps = Int(seconds * 120)
    return (0..<steps).map { from + (to - from) * Double($0) / Double(max(steps - 1, 1)) }
}

private func hold(_ speed: Double, seconds: Double) -> [Double] {
    Array(repeating: speed, count: Int(seconds * 120))
}

private func glides(_ pulses: [(time: Double, pulse: MotionModel.Pulse)]) -> [Double] {
    pulses.compactMap { if case .glide = $0.pulse { $0.time } else { nil } }
}

struct MotionModelTests {
    @Test func `careful reading is silent`() {
        var model = MotionModel()
        #expect(drive(&model, speeds: hold(300, seconds: 2)).isEmpty)
        #expect(!model.inMotion)
    }

    @Test func `a gradual build glides without a swell`() {
        var model = MotionModel()
        let pulses = drive(&model, speeds: ramp(from: 200, to: 1300, seconds: 1) + hold(1300, seconds: 1))
        #expect(!pulses.isEmpty)
        #expect(pulses.allSatisfy { $0.pulse != .swell })
    }

    @Test func `motion builds instead of snapping on`() {
        var model = MotionModel()
        var entry: Double?
        var first: Double?
        let speeds = ramp(from: 200, to: 2000, seconds: 0.6) + hold(2000, seconds: 0.5)
        for (index, speed) in speeds.enumerated() {
            let time = Double(index) / 120
            let pulse = model.update(delta: -speed / 120, time: time)
            if model.inMotion, entry == nil { entry = time }
            if pulse != nil, first == nil { first = time }
        }
        let started = try! #require(entry)
        let pulsed = try! #require(first)
        #expect(pulsed - started >= model.tuning.firstGlideDelay - 1e-9)
        // …but soon enough to be felt before a swipe's fingers lift.
        #expect(pulsed - started < 0.1)
    }

    @Test func `faster motion brings closer, gentler pulses`() {
        var slow = MotionModel()
        let slowTimes = glides(drive(&slow, speeds: ramp(from: 200, to: 1000, seconds: 0.5) + hold(1000, seconds: 2)))
        var fast = MotionModel()
        let fastPulses = drive(&fast, speeds: ramp(from: 200, to: 3400, seconds: 1.5) + hold(3400, seconds: 2))
        let fastTimes = glides(fastPulses)
        #expect(fastTimes.count > slowTimes.count)

        func gap(_ times: [Double]) -> Double { zip(times, times.dropFirst()).map { $1 - $0 }.last ?? .infinity }
        #expect(gap(fastTimes) < gap(slowTimes))
        // Never a machine gun.
        #expect(zip(fastTimes, fastTimes.dropFirst()).allSatisfy { $1 - $0 >= 0.065 })

        let levels = fastPulses.compactMap { if case let .glide(level) = $0.pulse { level } else { nil } }
        #expect(levels.last! < levels.first!)
        #expect(levels.allSatisfy { (0.6...1).contains($0) })
    }

    @Test func `a burst of acceleration is one swell`() {
        var model = MotionModel()
        let pulses = drive(&model, speeds: ramp(from: 100, to: 3200, seconds: 0.08) + hold(3200, seconds: 0.6))
        #expect(pulses.filter { $0.pulse == .swell }.count == 1)
        #expect(pulses.first?.pulse == .swell)
        // The glide follows the swell closely, without blurring into it.
        let gap = pulses[1].time - pulses[0].time
        #expect(gap > 0.05 && gap < 0.1)
    }

    @Test func `deceleration thins the glide until it stops`() {
        var model = MotionModel()
        // A fling: fast, then momentum decaying the way macOS's does.
        var speeds = hold(2600, seconds: 0.4)
        var speed = 2600.0
        while speed > 50 {
            speed *= 0.985
            speeds.append(speed)
        }
        let times = glides(drive(&model, speeds: speeds))
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.count >= 3)
        #expect(gaps.last! > gaps.first!)
        #expect(!model.inMotion)
        // Nothing once the speed falls below the exit level.
        let exitSpeed = model.tuning.threshold * model.tuning.exitRatio
        let quietFrom = Double(speeds.firstIndex { $0 < exitSpeed * 0.9 }!) / 120
        #expect(times.allSatisfy { $0 < quietFrom })
    }

    @Test func `holding at the page end stays silent until the next gesture`() {
        var model = MotionModel()
        _ = drive(&model, speeds: hold(2500, seconds: 0.3))
        model.hold()
        #expect(drive(&model, speeds: hold(2500, seconds: 0.5), start: 0.3).isEmpty)
        model.reset()
        #expect(!drive(&model, speeds: hold(2500, seconds: 0.5), start: 1).isEmpty)
    }

    @Test func `another swipe keeps the speed and clears a hold`() {
        var model = MotionModel()
        _ = drive(&model, speeds: hold(2500, seconds: 0.3))
        model.hold()
        model.newGesture()
        #expect(model.speed > 1500)
        // Gliding again straight away, with no new build-up.
        #expect(!drive(&model, speeds: hold(2500, seconds: 0.2), start: 0.3 + 1.0 / 120).isEmpty)
    }

    @Test func `a change of direction starts over`() {
        var model = MotionModel()
        _ = drive(&model, speeds: hold(2500, seconds: 0.3))
        #expect(model.inMotion)
        _ = model.update(delta: 2, time: 0.31)
        #expect(!model.inMotion)
        #expect(model.speed < 1000)
    }

    @Test func `a pause starts over`() {
        var model = MotionModel()
        _ = drive(&model, speeds: hold(2500, seconds: 0.3))
        _ = model.update(delta: -2, time: 1)
        #expect(!model.inMotion)
    }

    @Test func `thresholds and intensity tune the response`() {
        let profile = ramp(from: 200, to: 1000, seconds: 0.5) + hold(1000, seconds: 1.5)
        var late = MotionModel(tuning: .init(threshold: .late))
        #expect(drive(&late, speeds: profile).isEmpty)
        var early = MotionModel(tuning: .init(threshold: .early))
        #expect(!drive(&early, speeds: profile).isEmpty)

        let fast = ramp(from: 200, to: 2400, seconds: 0.8) + hold(2400, seconds: 1.5)
        var subtle = MotionModel(tuning: .init(intensity: .subtle))
        var lively = MotionModel(tuning: .init(intensity: .lively))
        #expect(glides(drive(&lively, speeds: fast)).count > glides(drive(&subtle, speeds: fast)).count)
    }
}
