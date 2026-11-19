#if DEBUG
import AppKit
import PulseCore
import SwiftUI

/// `Pulse --snapshot-ui <folder>` (debug builds only): renders every setup
/// step in every state, in setup and in the tutorial, and each settings pane
/// to PNGs, off screen, so layouts can be checked (and the README's
/// screenshots made) without showing a window.
enum UISnapshots {
    /// How far down the tour's mid-page snapshot opens.
    static var tourScroll: CGFloat = 330
    /// The README's hero is 1400 × 810: the whole tour window, centred on
    /// a canvas that wide.
    static var heroAspect: CGFloat = 1400.0 / 810.0

    /// One setup step in one state, as a snapshot names it.
    private struct Shot {
        var step: SetupStep
        var state: String?
        var tutorialOnly = false
        var trusted = true
        var keyboard: KeyboardController.Status = .playing
        var scroll: CGFloat?
        var felt: [Cue] = []
        var hero = false
    }

    /// Every step and state the setup and the tutorial can show.
    private static let shots: [Shot] = [
        Shot(step: .tour, state: nil),
        Shot(step: .tour, state: "felt", scroll: tourScroll, felt: [.actionable, .action, .caution, .navigation, .landmark]),
        Shot(step: .permission, state: nil, trusted: false),
        Shot(step: .permission, state: "granted"),
        Shot(step: .typing, state: nil),
        Shot(step: .typing, state: "no-access", trusted: false, keyboard: .off),
        Shot(step: .typing, state: "muted", keyboard: .mutedByUser),
        Shot(step: .typing, state: "paused", keyboard: .mediaPlaying),
        Shot(step: .done, state: nil),
        Shot(step: .tour, state: nil, tutorialOnly: true),
        Shot(step: .typing, state: nil, tutorialOnly: true),
        Shot(step: .done, state: nil, tutorialOnly: true),
        Shot(step: .tour, state: nil, felt: [.actionable, .action, .caution], hero: true),
    ]

    static func render(to folder: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let store = SettingsStore(defaults: UserDefaults(suiteName: "pulse.snapshots") ?? .standard)
        let previewer = CuePreviewer(haptics: HapticOutput(), audio: CueAudio(), store: store)
        let url = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        for muted in [false, true] {
            let glyph = PulseLogo.statusImage(muted: muted)
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = glyph.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                glyph.draw(in: CGRect(origin: .zero, size: glyph.size))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("menubar-\(muted ? "muted" : "on").png"))
            }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            // Setup as a first run finds it; Settings on Mechanical, so its board picker shows.
            store.value.keyboardProfile = PulseSettings().keyboardProfile
            for shot in shots {
                let model = SetupModel(store: store, previewer: previewer, tutorialOnly: shot.tutorialOnly, keyboard: shot.keyboard)
                model.step = shot.step
                model.trusted = shot.trusted
                for cue in shot.felt { model.tour.played(cue, felt: true) }
                TourScrollView.snapshotScroll = shot.scroll
                let mode = shot.tutorialOnly ? "tutorial" : "setup"
                let index = model.steps.firstIndex(of: shot.step) ?? 0
                let name = shot.hero ? "hero" : "\(mode)-\(index)-\(shot.step)" + (shot.state.map { "-\($0)" } ?? "")
                save(SetupView(model: model, store: store), size: SetupWindowController.size, style: SetupWindowController.style,
                     appearance: appearance, aspect: shot.hero ? heroAspect : nil, to: url.appendingPathComponent("\(name)-\(suffix).png"))
            }
            store.value.keyboardProfile = .mechanical
            for pane in SettingsPane.allCases {
                save(SettingsView(store: store, previewer: previewer, pane: pane), size: SettingsView.size,
                     style: [.titled, .closable, .miniaturizable, .fullSizeContentView], appearance: appearance,
                     to: url.appendingPathComponent("settings-\(pane.rawValue)-\(suffix).png"))
            }
        }
    }

    /// The whole window as on screen (title bar and buttons included), with
    /// rounded corners and a soft shadow, like a window screenshot. `aspect`
    /// widens the canvas to that width over height, the window centred.
    private static func save<V: View>(_ view: V, size: CGSize, style: NSWindow.StyleMask, appearance: NSAppearance.Name,
                                      aspect: CGFloat? = nil, to url: URL) {
        let window = KeyWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                               styleMask: style, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderBack(nil)
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // The window's frame view draws the title bar and its buttons too.
        let frame = hosting.superview ?? hosting
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try? framed(bitmap, size: frame.bounds.size, dark: appearance == .darkAqua, aspect: aspect)?
            .representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    /// The app never activates while snapshotting, so its windows would draw
    /// as background windows: grey switches, default button and window
    /// buttons. This one draws as the window in front. `hasKeyAppearance` is
    /// AppKit's own, undocumented, getter; without it snapshots go back to grey.
    private final class KeyWindow: NSWindow {
        @objc var hasKeyAppearance: Bool { true }
    }

    private static func framed(_ bitmap: NSBitmapImageRep, size: CGSize, dark: Bool, aspect: CGFloat?) -> NSBitmapImageRep? {
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let margin: CGFloat = 32
        var canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        if let aspect { canvas.width = max(canvas.width, (canvas.height * aspect).rounded()) }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = CGRect(x: (canvas.width - size.width) / 2, y: margin, width: size.width, height: size.height)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        // Shadows are drawn in pixels, whatever the context's scale.
        shadow.shadowBlurRadius = 22 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        bitmap.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        // The hairline edge macOS draws around a window.
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.16)).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 10, yRadius: 10)
        edge.lineWidth = 0.5
        edge.stroke()
        return rep
    }
}
#endif
