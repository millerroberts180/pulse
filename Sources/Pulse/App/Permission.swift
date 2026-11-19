import AppKit
import ApplicationServices

/// The single Accessibility permission Pulse needs, explained before it's
/// requested.
final class AccessibilityPermission {
    var onGranted: (() -> Void)?
    private var timer: Timer?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func explainAndRequest() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Pulse needs Accessibility access"
        alert.informativeText = """
            Pulse reads the roles, states, and positions of controls and headings \
            that macOS exposes, and turns them into small haptic cues. It also \
            notices key presses to play typing sounds.

            It never keeps page text, URLs, form values, or what you type, and \
            nothing leaves your Mac.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        waitForGrant()
    }

    /// Polls until the user flips the switch in System Settings.
    func waitForGrant() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isTrusted else { return }
                self.timer?.invalidate()
                self.timer = nil
                self.onGranted?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
