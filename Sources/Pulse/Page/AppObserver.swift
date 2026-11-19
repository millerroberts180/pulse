import AppKit
import ApplicationServices
import PulseCore

/// Listens to the frontmost app's accessibility notifications: keyboard focus
/// moving, the selected item in a list or sidebar changing, and live regions
/// (where web pages announce alerts and validation errors). Notifications
/// registered on the application element arrive for all of its elements.
///
/// With waypoints on, a second observer listens for a browser's find bar
/// landing on a match. It is separate because it needs notification details,
/// and only its two notifications are ever looked at.
final class AppObserver {
    var onFocus: ((AXRef) -> Void)?
    var onSelectionChange: ((AXRef) -> Void)?
    var onLiveRegion: ((AXRef) -> Void)?
    var onFindSignal: ((AXRef, FindSignal) -> Void)?

    private var observer: AXObserver?
    private var findObserver: AXObserver?
    private var appElement: AXUIElement?
    private(set) var pid: pid_t?
    private var observesFind = false

    private static let notifications = [
        "AXFocusedUIElementChanged",
        "AXSelectedChildrenChanged",
        "AXSelectedRowsChanged",
        "AXLiveRegionChanged",
        "AXLiveRegionCreated",
    ]

    private static let findNotifications = ["AXSelectedTextChanged", "AXAnnouncementRequested"]

    func observe(pid: pid_t?, findMatches: Bool = false) {
        guard pid != self.pid || findMatches != observesFind else { return }
        detach()
        guard let pid, pid != getpid() else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, appObserverCallback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Electron (and Chromium) build their web accessibility tree on request.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        appElement = app
        self.pid = pid

        if findMatches {
            var find: AXObserver?
            if AXObserverCreateWithInfoCallback(pid, findObserverCallback, &find) == .success, let find {
                for name in Self.findNotifications {
                    AXObserverAddNotification(find, app, name as CFString, refcon)
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(find), .commonModes)
                findObserver = find
            }
        }
        observesFind = findMatches
    }

    func detach() {
        if let findObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(findObserver), .commonModes)
            if let appElement {
                for name in Self.findNotifications {
                    AXObserverRemoveNotification(findObserver, appElement, name as CFString)
                }
            }
        }
        findObserver = nil
        observesFind = false
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let appElement {
                for name in Self.notifications {
                    AXObserverRemoveNotification(observer, appElement, name as CFString)
                }
            }
        }
        observer = nil
        appElement = nil
        pid = nil
    }

    fileprivate func handle(_ ref: AXRef, _ notification: String) {
        switch notification {
        case "AXFocusedUIElementChanged": onFocus?(ref)
        case "AXSelectedChildrenChanged", "AXSelectedRowsChanged": onSelectionChange?(ref)
        case "AXLiveRegionChanged", "AXLiveRegionCreated": onLiveRegion?(ref)
        default: break
        }
    }

    fileprivate func handleFind(_ ref: AXRef, _ signal: FindSignal) {
        onFindSignal?(ref, signal)
    }
}

/// What a browser's find bar reported.
nonisolated enum FindSignal: Sendable {
    /// Safari: the selection in the page moved (to a match, if the find bar has focus).
    case selection
    /// Chromium: the find bar announced its count; whether it names a match.
    case announcement(hasMatch: Bool)
}

/// The observer's source is on the main run loop, so this runs on main.
private nonisolated func appObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    let ref = AXRef(element)
    let name = notification as String
    MainActor.assumeIsolated { observer.handle(ref, name) }
}

/// Runs on main. Reads only the announcement's match count, in memory: the
/// text is browser UI ("Result 2 of 7") and is dropped immediately.
private nonisolated func findObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
    _ info: CFDictionary, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
    let signal: FindSignal
    switch notification as String {
    case "AXSelectedTextChanged":
        signal = .selection
    case "AXAnnouncementRequested":
        let text = (info as NSDictionary)["AXAnnouncementKey"] as? String
        signal = .announcement(hasMatch: text.map(FindAnnouncement.isMatch) ?? false)
    default:
        return
    }
    let ref = AXRef(element)
    MainActor.assumeIsolated { observer.handleFind(ref, signal) }
}
