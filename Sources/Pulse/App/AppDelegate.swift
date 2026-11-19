import AppKit
import PulseCore

/// Wires Pulse together. Detectors run only while Accessibility is granted,
/// and every listener tears down when it isn't needed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private let permission = AccessibilityPermission()
    private let haptics = HapticOutput()
    private let audio = CueAudio()
    private let muteHotKey = MuteHotKey()
    private let releaseClick = ReleaseClick()
    private let media = MediaMonitor()
    private var signalSources: [DispatchSourceSignal] = []
    private lazy var page = PageDetector(haptics: haptics)
    private lazy var keyboard = KeyboardController(audio: audio, haptics: haptics)
    private lazy var menu = MenuController(store: store)
    private lazy var previewer = CuePreviewer(haptics: haptics, audio: audio, store: store)
    private var observers: [NSObjectProtocol] = []

    private var setupWindow: SetupWindowController?
    private var settingsWindow: HostedWindow<SettingsView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TrialLeftovers.remove()
        store.onChange = { [weak self] in self?.apply() }

        menu.status = { [weak self] in self?.menuStatus() ?? .init(appName: nil, trusted: false, awareness: .unknown, keyboard: .off, frontmostExcluded: false) }
        menu.onRequestPermission = { [weak self] in self?.permission.explainAndRequest() }
        menu.onToggleFrontmostExclusion = { [weak self] in self?.toggleFrontmostExclusion() }
        menu.onMenuOpen = { [weak self] open in self?.page.isPaused = open }
        menu.onShowSettings = { [weak self] in self?.showSettings() }
        quitCleanlyOnSignals()

        page.isOwnWindow = { [weak self] point in self?.isOwnWindow(at: point) ?? false }
        page.onCue = { [weak self] cue, level in self?.playCueSound(cue, level: level) }
        media.onChange = { [weak self] in self?.apply() }

        muteHotKey.onPress = { [weak self] in self?.store.value.muted.toggle() }
        muteHotKey.register()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostChanged() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.page.windowsChanged() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.page.forget(pid: pid) }
            }
        })

        apply()
        permission.onGranted = { [weak self] in self?.startDetectors() }
        if permission.isTrusted {
            startDetectors()
        } else {
            permission.waitForGrant()
        }
        // The setup teaches every cue before real browsing, and asks for the
        // permission itself. Shown once; Settings › General reopens it as the
        // tutorial.
        if !UserDefaults.standard.bool(forKey: SetupWindowController.completedKey) {
            showSetup()
        }
    }

    /// Opening Pulse again while it runs, from Finder or Line Apps' menu, opens Settings: the way in
    /// while its icon is collapsed into Line Apps' line.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
        releaseClick.restore()
    }

    /// `kill` sends a signal rather than a quit event. Make it an ordinary
    /// quit, so the trackpad gets its release click back.
    private func quitCleanlyOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startDetectors() {
        detectorsRunning = true
        page.start()
        keyboard.start()
        apply()
    }

    private var detectorsRunning = false

    /// Accessibility can be revoked while Pulse runs. Taps and queries then
    /// fail silently, so stand down and wait for it to come back.
    private func checkTrust() {
        guard detectorsRunning, !permission.isTrusted else { return }
        detectorsRunning = false
        page.stop()
        keyboard.stop()
        media.stop()
        permission.waitForGrant()
    }

    // MARK: - Windows

    private func showSetup() {
        if setupWindow == nil {
            // After the first time, it's only the tutorial.
            let controller = SetupWindowController(
                store: store, previewer: previewer,
                tutorialOnly: UserDefaults.standard.bool(forKey: SetupWindowController.completedKey),
                onRequestPermission: { [weak self] in self?.permission.waitForGrant() },
                onTypingDemo: { [weak self] active in self?.keyboard.setDemo("setup", active: active) }
            )
            controller.onClose = { [weak self] in self?.setupWindow = nil }
            setupWindow = controller
        }
        setupWindow?.present()
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = HostedWindow(title: "Pulse Settings", size: SettingsView.size, sidebar: true) {
                SettingsView(
                    store: store, previewer: previewer,
                    releaseClickUnavailable: { [weak self] in self?.releaseClick.isUnavailable ?? false },
                    onShowSetup: { [weak self] in self?.showSetup() },
                    onTestHaptic: { [weak self] in self?.haptics.playTest() },
                    onTypingDemo: { [weak self] active in self?.keyboard.setDemo("settings", active: active) }
                )
            }
        }
        settingsWindow?.present()
    }

    /// Whether Pulse's menu-bar item, or one of its windows, is what's in
    /// front at a point (accessibility, top-left coordinates). Those are never
    /// hit-tested, and scrolling there (the setup's tour) is handled by the
    /// window itself. A Pulse window hidden behind another app's doesn't count.
    private func isOwnWindow(at point: CGPoint) -> Bool {
        if menu.buttonFrame?.contains(point) == true { return true }
        guard let primary = NSScreen.screens.first else { return false }
        let location = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        // Cheap first: is the point inside one of our windows at all?
        guard NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(location) }) else { return false }
        let front = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: front) != nil
    }

    private var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private var frontmostExcluded: Bool {
        frontmostBundleID.map(store.value.excludedApps.contains) ?? false
    }

    private func frontmostChanged() {
        checkTrust()
        // Exclusion first, so an excluded app never gets observers attached
        // (attaching one makes Chromium build its accessibility tree).
        apply()
        page.frontmostChanged()
    }

    private func apply() {
        let settings = store.value
        haptics.isMuted = settings.muted || !settings.hapticsEnabled
        haptics.strength = settings.hapticStrength
        page.options = settings.pageOptions
        page.excludedApps = settings.excludedApps
        // Which cues run (felt, heard, or both) is in the options themselves.
        page.isExcluded = settings.muted || frontmostExcluded
        // Only while Pulse adds haptics of its own; otherwise clicks feel as macOS made them.
        releaseClick.setSilenced(settings.silenceReleaseClick && !settings.muted && settings.hapticsEnabled)
        // Other apps' audio only matters while one of Pulse's sounds could play.
        if detectorsRunning, settings.quietWhileMediaPlays, settings.anySound {
            media.start()
        } else {
            media.stop()
        }
        keyboard.apply(settings, frontmostExcluded: frontmostExcluded, mediaPlaying: media.isPlaying)
        menu.refreshIcon()
    }

    private func toggleFrontmostExclusion() {
        guard let id = frontmostBundleID, id != Bundle.main.bundleIdentifier else { return }
        if store.value.excludedApps.contains(id) {
            store.value.excludedApps.remove(id)
        } else {
            store.value.excludedApps.insert(id)
        }
    }

    /// The sound that goes with a page or motion cue, when it's wanted.
    private func playCueSound(_ cue: Cue, level: Float) {
        let settings = store.value
        guard !settings.muted, !(settings.quietWhileMediaPlays && media.isPlaying) else { return }
        let wanted = switch cue {
        case .glide, .swell: settings.motionSounds
        // Hovered too often to sound alongside their haptic: theirs is the
        // audio-only form.
        case .actionable, .action: settings.pageSounds && !settings.hapticsEnabled
        case .capsLockOn, .capsLockOff, .chord, .repeatWarning: false
        default: settings.pageSounds
        }
        guard wanted, SoundSynth.hasPageSound(cue) else { return }
        var gain = settings.cueVolume * level
        if cue == .glide || cue == .swell { gain *= settings.motionIntensity.soundGain }
        audio.prepareIfNeeded()
        audio.play(.page(cue), gain: gain)
    }

    private func menuStatus() -> MenuController.Status {
        let app = NSWorkspace.shared.frontmostApplication
        let isSelf = app?.bundleIdentifier == Bundle.main.bundleIdentifier
        return MenuController.Status(
            appName: isSelf ? nil : app?.localizedName,
            trusted: permission.isTrusted,
            awareness: page.awareness(for: app?.processIdentifier),
            keyboard: keyboard.status,
            frontmostExcluded: frontmostExcluded,
            releaseClickUnavailable: releaseClick.isUnavailable,
            mediaPlaying: media.isPlaying
        )
    }
}
