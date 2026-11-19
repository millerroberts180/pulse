import AVFAudio
import Darwin
import Foundation
import PulseCore
import QuartzCore
import os

/// Every voice rendered once into one contiguous block of PCM. Immutable after
/// init, so any thread may read it.
nonisolated final class SoundBank: @unchecked Sendable {
    struct Clip { var start: Int; var length: Int }

    let sampleRate: Double
    let id: Int
    private let samples: UnsafeMutableBufferPointer<Float>
    private let clips: [VoiceKey: [Clip]]

    var base: UnsafePointer<Float> { UnsafePointer(samples.baseAddress!) }
    var byteCount: Int { samples.count * MemoryLayout<Float>.size }

    let board: KeyboardBoard

    init(sampleRate: Double, id: Int, board: KeyboardBoard = .creamy) {
        self.sampleRate = sampleRate
        self.id = id
        self.board = board
        var rendered: [(VoiceKey, [[Float]])] = []
        var total = 0
        for voice in SoundSynth.allVoices {
            // Playback always uses one stable take, so render only that one.
            let takes = [SoundSynth.render(voice, variant: 0, sampleRate: sampleRate, board: board)]
            total += takes.reduce(0) { $0 + $1.count }
            rendered.append((voice, takes))
        }
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(total, 1))
        buffer.initialize(repeating: 0)
        var offset = 0
        var clips: [VoiceKey: [Clip]] = [:]
        for (voice, takes) in rendered {
            clips[voice] = takes.map { take in
                _ = UnsafeMutableBufferPointer(rebasing: buffer[offset..<offset + take.count]).update(from: take)
                defer { offset += take.count }
                return Clip(start: offset, length: take.count)
            }
        }
        samples = buffer
        self.clips = clips
    }

    deinit { samples.deallocate() }

    func clips(for voice: VoiceKey) -> [Clip] { clips[voice] ?? [] }
}

/// A fixed pool of voices mixed inside the audio render callback. The render
/// thread never blocks and never allocates: triggers are handed over through a
/// small queue it only *tries* to lock, and voices live in preallocated memory.
nonisolated final class Mixer: @unchecked Sendable {
    struct Trigger {
        var start: Int
        var length: Int
        var gain: Float
        var bankID: Int
        var issued: UInt64
    }

    private struct Voice {
        var position = 0
        var end = 0
        var gain: Float = 0
        var active = false
        var order: UInt64 = 0
    }

    static let pendingCapacity = 32
    static let voiceCapacity = 12

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let pending: UnsafeMutablePointer<Trigger>
    private var pendingCount = 0 // Guarded by `lock`.
    private var lastTrigger: UInt64 = 0 // Guarded by `lock`.

    // Render thread only (or while the engine is stopped).
    private let voices: UnsafeMutablePointer<Voice>
    private var bank: UnsafePointer<Float>?
    private var bankID = -1
    private var order: UInt64 = 0
    /// Triggers older than this never play: a late click is worse than none.
    private let staleAfter: UInt64

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending = .allocate(capacity: Self.pendingCapacity)
        voices = .allocate(capacity: Self.voiceCapacity)
        voices.initialize(repeating: Voice(), count: Self.voiceCapacity)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        staleAfter = 120_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer) // 120 ms
    }

    deinit {
        lock.deallocate()
        pending.deallocate()
        voices.deallocate()
    }

    /// Any thread.
    func enqueue(_ trigger: Trigger) {
        os_unfair_lock_lock(lock)
        if pendingCount < Self.pendingCapacity {
            pending[pendingCount] = trigger
            pendingCount += 1
        }
        lastTrigger = trigger.issued
        os_unfair_lock_unlock(lock)
    }

    /// Host time of the latest trigger, for idle detection. Any thread.
    var lastTriggerTime: UInt64 {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return lastTrigger
    }

    /// Only while the engine is stopped: the render thread isn't running.
    func install(_ bank: SoundBank) {
        self.bank = bank.base
        bankID = bank.id
        for index in 0..<Self.voiceCapacity { voices[index].active = false }
        os_unfair_lock_lock(lock)
        pendingCount = 0
        os_unfair_lock_unlock(lock)
    }

    /// Render thread. Mixes every active voice into `output` (mono). Returns
    /// false when the buffer is silence.
    func render(frames: Int, into output: UnsafeMutablePointer<Float>) -> Bool {
        if os_unfair_lock_trylock(lock) {
            let now = mach_absolute_time()
            for index in 0..<pendingCount {
                let trigger = pending[index]
                guard trigger.bankID == bankID, now &- trigger.issued < staleAfter else { continue }
                start(trigger)
            }
            pendingCount = 0
            os_unfair_lock_unlock(lock)
        }
        output.update(repeating: 0, count: frames)
        guard let bank else { return false }
        var sounding = false
        for index in 0..<Self.voiceCapacity where voices[index].active {
            sounding = true
            let voice = voices[index]
            let count = min(voice.end - voice.position, frames)
            let source = bank + voice.position
            for frame in 0..<count {
                output[frame] += source[frame] * voice.gain
            }
            voices[index].position += count
            if voices[index].position >= voice.end { voices[index].active = false }
        }
        guard sounding else { return false }
        for frame in 0..<frames {
            output[frame] = min(max(output[frame], -1), 1)
        }
        return true
    }

    private func start(_ trigger: Trigger) {
        // A free voice, or steal the oldest.
        var slot = 0
        var oldest = UInt64.max
        for index in 0..<Self.voiceCapacity {
            if !voices[index].active { slot = index; oldest = 0; break }
            if voices[index].order < oldest { oldest = voices[index].order; slot = index }
        }
        order &+= 1
        voices[slot] = Voice(
            position: trigger.start, end: trigger.start + trigger.length,
            gain: trigger.gain, active: true, order: order
        )
    }

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { [unowned(unsafe) self] isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let output = data.assumingMemoryBound(to: Float.self)
            let frames = Int(frameCount)
            // Lets Core Audio skip mixing downstream while nothing plays.
            isSilence.pointee = ObjCBool(!self.render(frames: frames, into: output))
            // Any further channels get the same mono signal.
            for buffer in buffers.dropFirst() {
                buffer.mData?.assumingMemoryBound(to: Float.self).update(from: output, count: frames)
            }
            return noErr
        }
    }
}

/// Plays Pulse's sounds: keyboard voices and optional page-cue tones, through
/// one engine and one mixer node. The engine runs only while sounds are
/// wanted and stops itself after a minute of silence.
final class CueAudio {
    nonisolated let mixer = Mixer()
    /// Created on first use: with every sound off, Pulse never touches audio.
    private lazy var engine: AVAudioEngine = {
        let engine = AVAudioEngine()
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        return engine
    }()
    private var sourceNode: AVAudioSourceNode?
    private var lastStartFailure: CFTimeInterval = -.infinity
    private let banks = OSAllocatedUnfairLock<SoundBank?>(initialState: nil)
    private let wantsEngine = OSAllocatedUnfairLock(initialState: false)
    private var idleTimer: Timer?
    private var nextBankID = 0
    /// The keyboard Mechanical and Ambient sound like; changing it re-renders the bank.
    private var board: KeyboardBoard = .creamy

    func setBoard(_ newBoard: KeyboardBoard) {
        guard newBoard != board else { return }
        board = newBoard
        // Only if a bank exists: with every sound off, nothing is rendered yet.
        if sourceNode != nil { rebuild() }
    }
    private let log = Logger(subsystem: "com.millerroberts.Pulse", category: "audio")

    /// Silence after which the engine stops to save power.
    private static let idleSeconds: Double = 60

    /// Any thread. Starts the engine on demand if it was idle.
    nonisolated func play(_ voice: VoiceKey, gain: Float) {
        guard gain > 0, let bank = banks.withLock({ $0 }) else { return }
        let clips = bank.clips(for: voice)
        guard !clips.isEmpty else { return }
        // A stable take is calmer than randomized samples, particularly when
        // keys are typed quickly. The sound bank retains alternate takes for
        // future profiles, but the background profile must not call attention
        // to individual keystrokes.
        let clip = clips[0]
        mixer.enqueue(.init(start: clip.start, length: clip.length, gain: gain, bankID: bank.id, issued: mach_absolute_time()))
        let needsStart = wantsEngine.withLock { wants in
            defer { wants = true }
            return !wants
        }
        if needsStart {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.startEngine() } }
        }
    }

    /// Renders the bank and builds the graph the first time a sound is wanted,
    /// so Pulse touches no audio hardware while every sound is off.
    func prepareIfNeeded() {
        if sourceNode == nil { rebuild() }
    }

    func stopEngine() {
        idleTimer?.invalidate()
        idleTimer = nil
        if engine.isRunning { engine.stop() }
        wantsEngine.withLock { $0 = false }
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        // No output device (or one mid-switch): don't retry on every key.
        guard CACurrentMediaTime() - lastStartFailure > 5 else {
            wantsEngine.withLock { $0 = false }
            return
        }
        if sourceNode == nil { rebuild() }
        do {
            try engine.start()
            scheduleIdleCheck()
        } catch {
            log.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            lastStartFailure = CACurrentMediaTime()
            wantsEngine.withLock { $0 = false }
        }
    }

    /// The output device changed (headphones, AirPods, a display). The engine
    /// has stopped itself; rebuild at the new rate and resume if sound was on,
    /// or keys would stay silent while `wantsEngine` still reads true.
    private func outputChanged() {
        rebuild()
        let wanted = wantsEngine.withLock { $0 }
        if wanted, !engine.isRunning { startEngine() }
    }

    /// (Re)connects the source node at the output's sample rate, rendering a
    /// new bank if the rate changed. Called at launch and on device changes.
    private func rebuild() {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 48_000
        if banks.withLock({ $0?.sampleRate }) != sampleRate || banks.withLock({ $0?.board }) != board {
            nextBankID += 1
            let bank = SoundBank(sampleRate: sampleRate, id: nextBankID, board: board)
            banks.withLock { $0 = bank }
        }
        if let bank = banks.withLock({ $0 }) { mixer.install(bank) }

        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let node = AVAudioSourceNode(format: format, renderBlock: mixer.makeRenderBlock())
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        if wasRunning { startEngine() }
    }

    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let idle = Double(mach_absolute_time() &- self.mixer.lastTriggerTime) * Self.hostSeconds
                if idle > Self.idleSeconds { self.stopEngine() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private static let hostSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()
}
