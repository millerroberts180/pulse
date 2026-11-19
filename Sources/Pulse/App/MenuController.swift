import AppKit
import PulseCore

/// The menu-bar item and its menu. Plain AppKit, rebuilt each time it opens,
/// so there is no UI state to keep in sync.
final class MenuController: NSObject, NSMenuDelegate {
    struct Status {
        var appName: String?
        var trusted: Bool
        var awareness: PageDetector.Awareness
        var keyboard: KeyboardController.Status
        var frontmostExcluded: Bool
        var releaseClickUnavailable = false
        var mediaPlaying = false
    }

    var status: () -> Status = { Status(appName: nil, trusted: false, awareness: .unknown, keyboard: .off, frontmostExcluded: false) }
    var onRequestPermission: (() -> Void)?
    var onToggleFrontmostExclusion: (() -> Void)?
    var onMenuOpen: ((Bool) -> Void)?
    var onShowSettings: (() -> Void)?

    private let store: SettingsStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    /// Hides the icon while Line Apps has the family collapsed into its line.
    private lazy var lineFold = LineAppsFold(
        setHidden: { [weak self] hidden in self?.statusItem.isVisible = !hidden },
        button: { [weak self] in self?.statusItem.button },
        name: { [weak self] in self?.statusItem.autosaveName }
    )

    init(store: SettingsStore) {
        self.store = store
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()
        lineFold.start()
    }

    /// The status item's frame in accessibility (top-left) coordinates.
    var buttonFrame: CGRect? {
        guard let frame = statusItem.button?.window?.frame, let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private var shownMuted: Bool?

    func refreshIcon() {
        let muted = store.value.muted
        guard muted != shownMuted else { return } // Called on every app switch.
        shownMuted = muted
        statusItem.button?.image = PulseLogo.statusImage(muted: muted)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) { onMenuOpen?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuOpen?(false) }

    /// Kept short and narrow: where Pulse stands, the two things you reach
    /// for in a hurry (mute, and off for this app), and Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = store.value
        let status = status()

        menu.addItem(disabled(statusLine(status)))
        if let quiet = keyboardQuietLine(status.keyboard) { menu.addItem(disabled(quiet)) }
        if !status.trusted {
            menu.addItem(item("Grant Access…") { [weak self] in self?.onRequestPermission?() })
        }
        menu.addItem(.separator())

        // The global hotkey works without being shown here; Settings names it.
        menu.addItem(item(settings.muted ? "Unmute" : "Mute") { [weak self] in self?.store.value.muted.toggle() })
        if let name = status.appName.map(Self.short) {
            menu.addItem(item(status.frontmostExcluded ? "Turn On in \(name)" : "Turn Off in \(name)") { [weak self] in
                self?.onToggleFrontmostExclusion?()
            })
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", key: ",") { [weak self] in self?.onShowSettings?() })
        menu.addItem(item("Quit Pulse", key: "q") { NSApp.terminate(nil) })
    }

    // MARK: - Status

    private func statusLine(_ status: Status) -> String {
        guard status.trusted else { return "Needs Accessibility" }
        if store.value.muted { return "Muted" }
        let settings = store.value
        if !settings.pageFeedback && !settings.motionFeedback { return "Page cues off" }
        guard let name = status.appName.map(Self.short) else { return "Pulse is on" }
        if status.frontmostExcluded { return "Off in \(name)" }
        return switch status.awareness {
        case .pageAware: "Page-aware in \(name)"
        case .motionOnly: "Motion-only in \(name)"
        case .unknown: "On in \(name)"
        }
    }

    /// Only when typing has gone quiet on its own, so the silence is explained.
    private func keyboardQuietLine(_ status: KeyboardController.Status) -> String? {
        switch status {
        case .microphoneInUse: "Typing paused: mic in use"
        case .mediaPlaying: "Typing paused: audio playing"
        case .voiceOverDefault: "Typing off for VoiceOver"
        case .unavailable: "Typing sound unavailable"
        case .off, .disabled, .playing, .hapticsOnly, .mutedByUser, .excludedApp: nil
        }
    }

    /// App names can be long ("Google Chrome for Testing"); the menu stays narrow.
    private static func short(_ name: String) -> String {
        name.count <= 14 ? name : name.prefix(13).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func name(_ profile: KeyboardProfile) -> String {
        switch profile {
        case .ambient: "Ambient"
        case .mechanical: "Mechanical"
        case .keySense: "KeySense"
        case .quiet: "Quiet"
        }
    }

    // MARK: - Item helpers

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let handler = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
        item.target = handler
        item.representedObject = handler // The target is weak; this keeps it alive.
        item.isEnabled = true
        return item
    }
}

/// The target of a menu item that runs a closure.
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
