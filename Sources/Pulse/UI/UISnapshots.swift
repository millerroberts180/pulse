#if DEBUG
import AppKit
import SwiftUI

/// `Pulse --snapshot-ui <folder>` (debug builds only): renders every setup
/// step and each settings pane to PNGs, off screen, so layouts can be checked
/// (and the README's screenshots made) without showing a window.
enum UISnapshots {
    /// How far down the tour snapshot opens.
    static var tourScroll: CGFloat = 590
    /// What the README's hero keeps of the cues step, in points from the
    /// window's top and bottom edges: down to just under the waypoint note,
    /// and the footer, so the empty band between them goes.
    static var heroKeeps = (top: CGFloat(410), bottom: CGFloat(49))

    static func render(to folder: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let store = SettingsStore(defaults: UserDefaults(suiteName: "pulse.snapshots") ?? .standard)
        // Mechanical, so the board picker shows.
        store.value.keyboardProfile = .mechanical
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
            for step in SetupModel.Step.allCases {
                let model = SetupModel(store: store, previewer: previewer)
                model.step = step
                if step == .tour {
                    // Partway down, a few cues in, as it looks in use.
                    TourScrollView.snapshotScroll = tourScroll
                    model.felt = [.landmark, .actionable]
                    model.lastTourCue = .actionable
                }
                save(SetupView(model: model, store: store), size: SetupWindowController.size, style: SetupWindowController.style,
                     appearance: appearance, to: url.appendingPathComponent("setup-\(step.rawValue)-\(step)-\(suffix).png"))
                if step == .cues {
                    save(SetupView(model: model, store: store), size: SetupWindowController.size, style: SetupWindowController.style,
                         appearance: appearance, keeping: heroKeeps, to: url.appendingPathComponent("hero-cues-\(suffix).png"))
                }
            }
            for pane in SettingsPane.allCases {
                save(SettingsView(store: store, previewer: previewer, pane: pane), size: SettingsView.size,
                     style: [.titled, .closable, .miniaturizable, .fullSizeContentView], appearance: appearance,
                     to: url.appendingPathComponent("settings-\(pane.rawValue)-\(suffix).png"))
            }
        }
    }

    /// The whole window as on screen (title bar and buttons included), with
    /// rounded corners and a soft shadow, like a window screenshot. `keeping`
    /// leaves out the middle, keeping that many points at the top and bottom.
    private static func save<V: View>(_ view: V, size: CGSize, style: NSWindow.StyleMask, appearance: NSAppearance.Name,
                                      keeping: (top: CGFloat, bottom: CGFloat)? = nil, to url: URL) {
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
        var image = (bitmap: bitmap, size: frame.bounds.size)
        if let keeping, let ends = ends(of: bitmap, size: image.size, keeping: keeping) { image = ends }
        try? framed(image.bitmap, size: image.size, dark: appearance == .darkAqua)?.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    /// The window's top and bottom, joined where the middle was.
    private static func ends(of bitmap: NSBitmapImageRep, size: CGSize,
                             keeping: (top: CGFloat, bottom: CGFloat)) -> (bitmap: NSBitmapImageRep, size: CGSize)? {
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let joined = CGSize(width: size.width, height: keeping.top + keeping.bottom)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(joined.width * scale), pixelsHigh: Int(joined.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = joined
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // The bottom strip, then the top one, each clipped to its own part.
        for (y, strip) in [(CGFloat(0), CGRect(x: 0, y: 0, width: joined.width, height: keeping.bottom)),
                           (joined.height - size.height, CGRect(x: 0, y: keeping.bottom, width: joined.width, height: keeping.top))] {
            NSGraphicsContext.saveGraphicsState()
            strip.clip()
            bitmap.draw(in: CGRect(x: 0, y: y, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        return (rep, joined)
    }

    /// The app never activates while snapshotting, so its windows would draw
    /// as background windows: grey switches, default button and window
    /// buttons. This one draws as the window in front. `hasKeyAppearance` is
    /// AppKit's own, undocumented, getter; without it snapshots go back to grey.
    private final class KeyWindow: NSWindow {
        @objc var hasKeyAppearance: Bool { true }
    }

    private static func framed(_ bitmap: NSBitmapImageRep, size: CGSize, dark: Bool) -> NSBitmapImageRep? {
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let margin: CGFloat = 32
        let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = CGRect(x: margin, y: margin, width: size.width, height: size.height)
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
