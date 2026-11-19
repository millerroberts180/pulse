import AppKit

/// Pulse's own mark, Soft Pulse: a flat line rising into one soft, round
/// pulse and settling, the shape of the haptic Pulse plays. One colour
/// (Pulse Violet, #5B4FE6) and white. Masters and the usage guide are in
/// design/logo. (SF Symbols may be used in an app's interface, but Apple's
/// license rules them out for app icons and logos.)
enum PulseLogo {
    static let violet = CGColor(srgbRed: 91 / 255, green: 79 / 255, blue: 230 / 255, alpha: 1)

    /// The symbol on its 256-unit grid (y down, as in the SVG master): stroke
    /// 24, round caps and joins.
    /// Geometry only, so any isolation can use it (SwiftUI shapes draw off the main actor).
    nonisolated static func symbolPath(small: Bool = false) -> CGPath {
        let path = CGMutablePath()
        if small {
            // The small-size cut: shorter tails and a taller pulse (stroke 32).
            path.move(to: CGPoint(x: 40, y: 184))
            path.addLine(to: CGPoint(x: 66, y: 184))
            path.addCurve(to: CGPoint(x: 128, y: 72), control1: CGPoint(x: 90, y: 184), control2: CGPoint(x: 92, y: 72))
            path.addCurve(to: CGPoint(x: 190, y: 184), control1: CGPoint(x: 164, y: 72), control2: CGPoint(x: 166, y: 184))
            path.addLine(to: CGPoint(x: 216, y: 184))
        } else {
            path.move(to: CGPoint(x: 28, y: 170))
            path.addLine(to: CGPoint(x: 62, y: 170))
            path.addCurve(to: CGPoint(x: 128, y: 82), control1: CGPoint(x: 88, y: 170), control2: CGPoint(x: 90, y: 82))
            path.addCurve(to: CGPoint(x: 194, y: 170), control1: CGPoint(x: 166, y: 82), control2: CGPoint(x: 168, y: 170))
            path.addLine(to: CGPoint(x: 228, y: 170))
        }
        return path
    }

    /// The app icon on Apple's 1024-unit macOS grid: an 824-unit body with
    /// corner radius 186 in Pulse Violet, a soft shadow, and the white symbol
    /// at 62 % of the grid, 2 % above centre. 32 px and below use the
    /// small-size cut, larger.
    static func drawIcon(in context: CGContext, pixels: CGFloat) {
        let scale = pixels / 1024
        let small = pixels <= 32
        context.saveGState()
        // Bitmap contexts are y-up; the drawing is on a y-down grid like the SVG.
        context.translateBy(x: 0, y: pixels)
        context.scaleBy(x: scale, y: -scale)

        let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
        context.saveGState()
        // Shadows ignore the context's scale (and its flip), so size them by hand.
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(body)
        context.setFillColor(violet)
        context.fillPath()
        context.restoreGState()

        let mark = small ? 3.0 : 2.48 // Symbol units per icon unit.
        context.translateBy(x: 512, y: 496)
        context.scaleBy(x: mark, y: mark)
        context.translateBy(x: -128, y: small ? -128 : -126)
        context.addPath(symbolPath(small: small))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(small ? 32 : 24)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    /// The app icon as an image, for About. Drawn here rather than taken from
    /// the bundle, so a bare debug build shows it too.
    static func iconImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawIcon(in: context, pixels: size)
            return true
        }
    }

    /// The symbol for the menu bar, as a template image. Muted, the pulse goes
    /// flat: no pulse.
    static func statusImage(muted: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The symbol's stroke spans x 16-240, y 70-182 on its grid: fit it
            // to 18 pt wide, centred, with a 2 pt stroke.
            let fit: CGFloat = 18 / 224
            context.translateBy(x: 1, y: 9)
            context.scaleBy(x: fit, y: fit)
            context.translateBy(x: -16, y: -126)
            if muted {
                context.move(to: CGPoint(x: 28, y: 126 + 22))
                context.addLine(to: CGPoint(x: 228, y: 126 + 22))
            } else {
                context.addPath(symbolPath())
            }
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(2 / fit)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = muted ? "Pulse, muted" : "Pulse"
        return image
    }

    #if DEBUG
    /// `Pulse --make-icon <file.icns>` (debug builds): renders the iconset and
    /// packs it with iconutil. scripts/make-icon.sh runs it.
    static func writeIcon(to path: String) -> Bool {
        let output = URL(fileURLWithPath: path)
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Pulse.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for density in [1, 2] {
                let pixels = points * density
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return false }
                graphics.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
                drawIcon(in: graphics.cgContext, pixels: CGFloat(pixels))
                graphics.flushGraphics()
                let name = density == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let png = rep.representation(using: .png, properties: [:]) else { return false }
                try? png.write(to: iconset.appendingPathComponent(name))
            }
        }
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        pack.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        do { try pack.run() } catch { return false }
        pack.waitUntilExit()
        try? FileManager.default.removeItem(at: iconset)
        return pack.terminationStatus == 0
    }
    #endif
}
