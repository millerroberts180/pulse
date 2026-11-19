import AppKit
import PulseCore
import os

/// Lets a trackpad click be felt once, on the way down.
///
/// A Force Touch trackpad's firmware plays two clicks: one as a press
/// registers and one as it lets go. Each is a waveform the system hands the
/// trackpad as a HID report (press 0x22, release 0x23). Silencing rewrites
/// only the release, as the same pulse at zero amplitude; the press, tap to
/// click and Force Click are untouched, so nothing has to stand in for them.
///
/// The system's own waveform is saved first, to disk as well, and written
/// back when Pulse stops, or at the next launch if Pulse never got to. The
/// system resends its clicks now and then (after sleep, when Trackpad
/// settings change, when a trackpad connects), so while silenced the report
/// is checked on wake and every half minute: one HID read per trackpad.
final class ReleaseClick {
    /// No trackpad here has a release click Pulse knows how to silence.
    private(set) var isUnavailable = false

    private var wanted = false
    /// A previous run left a click silenced; settle it on the first update.
    private var pendingRecovery: Bool
    private var driver: Driver?
    private var driverFailed = false
    private var actuators: [UInt64: UnsafeMutableRawPointer] = [:]
    /// The system's release click, by device ID, while Pulse has it silenced.
    private var saved: [UInt64: [UInt8]] {
        didSet { persist() }
    }
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.millerroberts.Pulse", category: "click")

    private static let savedKey = "releaseClick.saved"
    private static let releaseReport: UInt8 = 0x23

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.savedKey) as? [String: Data] ?? [:]
        saved = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            UInt64(key).map { ($0, [UInt8](value)) }
        })
        pendingRecovery = !saved.isEmpty
    }

    /// Cheap when nothing changes: called on every settings change.
    func setSilenced(_ on: Bool) {
        guard on != wanted || pendingRecovery else { return }
        wanted = on
        pendingRecovery = false
        if on {
            silence()
            watch()
        } else {
            stopWatching()
            restore()
        }
    }

    /// Puts every saved release click back. Safe to call more than once.
    func restore() {
        guard !saved.isEmpty, let driver = loadedDriver() else { return }
        refreshActuators(driver)
        for (id, original) in saved {
            // Only undo Pulse's own change; a click the system has since
            // resent is already the system's.
            guard let actuator = actuators[id], let current = driver.read(actuator, Self.releaseReport),
                  ClickWaveform.isSilent(current) else { continue }
            if !driver.write(actuator, Self.releaseReport, original) {
                log.error("Couldn't restore the release click on device \(id, privacy: .public)")
            }
        }
        saved = [:]
    }

    private func silence() {
        guard let driver = loadedDriver() else {
            isUnavailable = true
            return
        }
        refreshActuators(driver)
        var silenced = false
        for (id, actuator) in actuators {
            guard let current = driver.read(actuator, Self.releaseReport) else {
                // Disconnected or asleep: open it afresh next time.
                actuators[id] = nil
                Unmanaged<AnyObject>.fromOpaque(actuator).release()
                continue
            }
            if ClickWaveform.isSilent(current) {
                silenced = true
                continue
            }
            guard let quiet = ClickWaveform.silenced(current) else { continue }
            saved[id] = current
            if driver.write(actuator, Self.releaseReport, quiet), driver.read(actuator, Self.releaseReport) == quiet {
                silenced = true
            } else {
                _ = driver.write(actuator, Self.releaseReport, current)
                saved[id] = nil
            }
        }
        isUnavailable = !silenced
    }

    private func watch() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.silence() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.silence() }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func persist() {
        if saved.isEmpty {
            defaults.removeObject(forKey: Self.savedKey)
        } else {
            defaults.set(Dictionary(uniqueKeysWithValues: saved.map { (String($0.key), Data($0.value)) }), forKey: Self.savedKey)
        }
    }

    private func loadedDriver() -> Driver? {
        if driver == nil, !driverFailed {
            driver = Driver.make()
            driverFailed = driver == nil
            if driverFailed { log.notice("MultitouchSupport click reports unavailable") }
        }
        return driver
    }

    /// Opens an actuator for every haptic trackpad not yet known. Devices
    /// without a motor fail to open and are skipped.
    private func refreshActuators(_ driver: Driver) {
        for id in driver.deviceIDs() where actuators[id] == nil {
            if let actuator = driver.open(id) { actuators[id] = actuator }
        }
    }
}

/// The few MultitouchSupport calls a click report needs, resolved at runtime.
private struct Driver {
    private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuator = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenActuator = @convention(c) (UnsafeMutableRawPointer) -> Int32
    /// (actuator, report ID, buffer, buffer length, bytes the report holds)
    private typealias GetReport = @convention(c) (UnsafeMutableRawPointer, UInt8, UnsafeMutablePointer<UInt8>, Int32, UnsafeMutablePointer<UInt32>) -> Int32
    /// (actuator, report ID, bytes, length)
    private typealias SetReport = @convention(c) (UnsafeMutableRawPointer, UInt8, UnsafePointer<UInt8>, Int32) -> Int32

    private let listDevices: DeviceList
    private let deviceID: DeviceID
    private let createActuator: CreateActuator
    private let openActuator: OpenActuator
    private let getReport: GetReport
    private let setReport: SetReport

    static func make() -> Driver? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let list = dlsym(handle, "MTDeviceCreateList"),
              let id = dlsym(handle, "MTDeviceGetDeviceID"),
              let create = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let open = dlsym(handle, "MTActuatorOpen"),
              let get = dlsym(handle, "MTActuatorGetReport"),
              let set = dlsym(handle, "MTActuatorSetReport")
        else { return nil }
        return Driver(
            listDevices: unsafeBitCast(list, to: DeviceList.self),
            deviceID: unsafeBitCast(id, to: DeviceID.self),
            createActuator: unsafeBitCast(create, to: CreateActuator.self),
            openActuator: unsafeBitCast(open, to: OpenActuator.self),
            getReport: unsafeBitCast(get, to: GetReport.self),
            setReport: unsafeBitCast(set, to: SetReport.self)
        )
    }

    func deviceIDs() -> [UInt64] {
        guard let devices = listDevices()?.takeRetainedValue() as? [AnyObject] else { return [] }
        return devices.compactMap { device in
            var id: UInt64 = 0
            return deviceID(Unmanaged.passUnretained(device).toOpaque(), &id) == 0 && id != 0 ? id : nil
        }
    }

    func open(_ id: UInt64) -> UnsafeMutableRawPointer? {
        guard let actuator = createActuator(id) else { return nil }
        guard openActuator(actuator) == 0 else {
            Unmanaged<AnyObject>.fromOpaque(actuator).release()
            return nil
        }
        return actuator
    }

    func read(_ actuator: UnsafeMutableRawPointer, _ report: UInt8) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 16)
        var length: UInt32 = 0
        guard getReport(actuator, report, &buffer, Int32(buffer.count), &length) == 0,
              length > 0, length <= buffer.count else { return nil }
        return Array(buffer.prefix(Int(length)))
    }

    func write(_ actuator: UnsafeMutableRawPointer, _ report: UInt8, _ bytes: [UInt8]) -> Bool {
        setReport(actuator, report, bytes, Int32(bytes.count)) == 0
    }
}
