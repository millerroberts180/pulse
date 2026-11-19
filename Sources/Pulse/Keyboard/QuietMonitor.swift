import AppKit
import Carbon.HIToolbox
import CoreAudio

/// Signals that ask Pulse to be quiet without the user doing anything:
/// a call or dictation using the microphone, and VoiceOver running.
final class QuietMonitor {
    var onChange: (() -> Void)?

    private(set) var microphoneInUse = false
    private(set) var voiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled

    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var voiceOverObservation: NSKeyValueObservation?

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        voiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled
        // Any process recording from the default input means a call, a
        // meeting, or dictation. Pulse itself never records.
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachInputDevice() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            defaultDeviceListener = block
        }
        attachInputDevice()

        // KVO may notify on any thread: hop to main explicitly.
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { @Sendable [weak self] workspace, _ in
            let running = workspace.isVoiceOverEnabled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.voiceOverRunning = running
                    self?.onChange?()
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        detachInputDevice()
        if let defaultDeviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultDeviceListener)
        }
        defaultDeviceListener = nil
        voiceOverObservation = nil
        microphoneInUse = false
    }

    private func attachInputDevice() {
        detachInputDevice()
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { update(microphone: false); return }
        inputDevice = device

        var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readInputState() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &running, .main, block) == noErr {
            deviceListener = block
        }
        readInputState()
    }

    private func detachInputDevice() {
        if let deviceListener, inputDevice != kAudioObjectUnknown {
            var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(inputDevice, &running, .main, deviceListener)
        }
        deviceListener = nil
        inputDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func readInputState() {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let ok = AudioObjectGetPropertyData(inputDevice, &address, 0, nil, &size, &value) == noErr
        update(microphone: ok && value != 0)
    }

    private func update(microphone: Bool) {
        guard microphone != microphoneInUse else { return }
        microphoneInUse = microphone
        onChange?()
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// The single global mute hotkey (⌃⌥⌘M). Registered through Carbon, which
/// needs no permission and consumes the chord so the frontmost app never sees it.
final class MuteHotKey {
    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    static let display = "⌃⌥⌘M"

    func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), muteHotKeyHandler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x504C_5345), id: 1) // "PLSE"
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    fileprivate func pressed() { onPress?() }
}

/// Carbon delivers hot keys on the main thread.
private nonisolated func muteHotKeyHandler(
    _ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<MuteHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.pressed() }
    return noErr
}
