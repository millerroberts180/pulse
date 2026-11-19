import ApplicationServices
import Foundation

/// An accessibility element handle. AXUIElement is an immutable reference to a
/// remote element and the Accessibility API may be called with it from any
/// thread, so sharing it across threads is safe.
nonisolated struct AXRef: @unchecked Sendable, Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXRef, rhs: AXRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }

    /// Stable for the life of the remote element.
    var identity: Int { Int(bitPattern: UInt(CFHash(element))) }
}

/// What Pulse reads about an element, fetched in one round trip.
nonisolated struct AXInfo: Sendable {
    var role: String
    var subrole: String?
    var frame: CGRect?
    var enabled: Bool
}

/// Thin, allocation-light wrappers over the C Accessibility API. Every call is
/// a cross-process message bounded by the element's messaging timeout.
nonisolated enum AX {
    /// Per-message ceiling. A hung app can stall a query, never the pipeline.
    static let timeout: Float = 0.05

    static func element(at point: CGPoint, in root: AXUIElement) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element) == .success
        else { return nil }
        if let element { AXUIElementSetMessagingTimeout(element, timeout) }
        return element
    }

    static func pid(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid) // Reads the handle; no message is sent.
        return pid
    }

    /// Role, subrole, frame, and enabled state in a single message.
    static func info(_ element: AXUIElement) -> AXInfo {
        let values = attributes(element, ["AXRole", "AXSubrole", "AXPosition", "AXSize", "AXEnabled"])
        var frame: CGRect?
        if let origin = point(values[2]), let size = size(values[3]) {
            frame = CGRect(origin: origin, size: size)
        }
        return AXInfo(
            role: string(values[0]) ?? "",
            subrole: string(values[1]),
            frame: frame,
            enabled: bool(values[4]) ?? true
        )
    }

    /// Several attributes in one message. Missing attributes come back nil.
    static func attributes(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard result == .success, let array = values as? [CFTypeRef], array.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return array.map { value in
            // Per-attribute failures arrive as AXValues of the error type.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func parent(_ element: AXUIElement) -> AXUIElement? {
        self.element(attribute(element, "AXParent"))
    }

    /// The first `limit` children, without materializing huge web containers.
    static func children(_ element: AXUIElement, limit: Int) -> [AXUIElement] {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, limit, &values) == .success,
              let children = values as? [AXUIElement]
        else { return [] }
        for child in children { AXUIElementSetMessagingTimeout(child, timeout) }
        return children
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// The VoiceOver rotor's search: elements of a kind, in document order
    /// from `start`. Implemented by both WebKit and Chromium.
    static func search(
        in root: AXUIElement,
        key: String,
        from start: AXUIElement?,
        forward: Bool,
        limit: Int,
        visibleOnly: Bool
    ) -> [AXUIElement]? {
        var predicate: [String: Any] = [
            "AXSearchKey": key,
            "AXDirection": forward ? "AXDirectionNext" : "AXDirectionPrevious",
            "AXResultsLimit": limit,
            "AXVisibleOnly": visibleOnly,
            "AXImmediateDescendantsOnly": false,
        ]
        if let start { predicate["AXStartElement"] = start }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            root, "AXUIElementsForSearchPredicate" as CFString, predicate as CFDictionary, &result
        ) == .success else { return nil }
        let found = (result as? [AXUIElement]) ?? []
        for element in found { AXUIElementSetMessagingTimeout(element, timeout) }
        return found
    }

    // MARK: - Decoding

    static func string(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    static func bool(_ value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        return (value as? NSNumber)?.boolValue
    }

    static func number(_ value: CFTypeRef?) -> Double? {
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        let values = attributes(element, ["AXPosition", "AXSize"])
        guard let origin = point(values[0]), let size = size(values[1]) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
