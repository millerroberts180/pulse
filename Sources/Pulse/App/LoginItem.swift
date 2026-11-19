import ServiceManagement
import os

/// Open at login, through the system's own login-item list (System
/// Settings › General › Login Items), which stays the source of truth.
enum LoginItem {
    private static let log = Logger(subsystem: "com.millerroberts.Pulse", category: "login")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user turned it on but still has to allow it in System Settings.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
