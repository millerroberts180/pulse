import AppKit
import CoreAudio
import PulseCore
import os

/// Notices another app playing audio (music, a video, the far end of a call),
/// so Pulse's sounds step aside. Core Audio keeps one object per process that
/// uses audio, with whether its output is running, the way Tactile tells
/// which apps are playing (macOS 14.2 and later).
///
/// Short system sounds and speech are ignored: an alert shouldn't hush typing,
/// and VoiceOver's voice must never silence the cues meant to accompany it.
/// Playing has to last a moment to count, and silence a moment longer to end
/// it, so the gap between two tracks doesn't flicker sounds back on.
final class MediaMonitor {
    var onChange: (() -> Void)?

    private(set) var isPlaying = false
    private(set) var isRunning = false

    /// Process objects and the listener on each.
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private var settle: Timer?

    private static let log = Logger(subsystem: "com.millerroberts.Pulse", category: "quiet")
    private static let startDelay: TimeInterval = 1.2
    private static let endDelay: TimeInterval = 2.5

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    func start() {
        guard !isRunning, #available(macOS 14.2, *) else { return }
        isRunning = true
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshProcesses() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listListener = block
        }
        refreshProcesses()
    }

    func stop() {
        guard isRunning, #available(macOS 14.2, *) else { return }
        isRunning = false
        if let listListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listListener)
        }
        listListener = nil
        for id in Array(listeners.keys) { detach(id) }
        settle?.invalidate()
        settle = nil
        if isPlaying {
            isPlaying = false
            onChange?()
        }
    }

    @available(macOS 14.2, *)
    private func refreshProcesses() {
        guard isRunning else { return }
        let current = Set(Self.processObjects())
        for id in listeners.keys where !current.contains(id) { detach(id) }
        let own = getpid()
        for id in current where listeners[id] == nil {
            // Pulse's own output and ignored processes need no listener.
            guard Self.pid(of: id) != own, !QuietRules.isIgnoredAudioSource(bundleID: Self.bundleID(of: id)) else { continue }
            // "Is running output" posts no notification of its own; "is
            // running" does, whenever the process starts or stops audio I/O.
            var address = Self.address(kAudioProcessPropertyIsRunning)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
                listeners[id] = block
            }
        }
        evaluate()
    }

    private func detach(_ id: AudioObjectID) {
        guard #available(macOS 14.2, *), let block = listeners.removeValue(forKey: id) else { return }
        var address = Self.address(kAudioProcessPropertyIsRunning)
        AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
    }

    private func evaluate() {
        guard isRunning, #available(macOS 14.2, *) else { return }
        let playing = listeners.keys.contains { Self.uint32(kAudioProcessPropertyIsRunningOutput, of: $0) != 0 }
        guard playing != isPlaying else {
            settle?.invalidate()
            settle = nil
            return
        }
        guard settle == nil else { return }
        let timer = Timer(timeInterval: playing ? Self.startDelay : Self.endDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settle = nil
                let still = self.listeners.keys.contains { Self.uint32(kAudioProcessPropertyIsRunningOutput, of: $0) != 0 }
                guard still == playing, self.isPlaying != playing, self.isRunning else { return }
                self.isPlaying = playing
                Self.log.info("Other audio \(playing ? "playing" : "stopped", privacy: .public)")
                self.onChange?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        settle = timer
    }

    // MARK: - Core Audio

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    @available(macOS 14.2, *)
    private static func pid(of id: AudioObjectID) -> pid_t {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid) == noErr ? pid : -1
    }

    @available(macOS 14.2, *)
    private static func bundleID(of id: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
