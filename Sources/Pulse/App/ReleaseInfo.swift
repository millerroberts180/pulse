import Foundation

/// Where Pulse points people, and what it says about itself: read from the
/// bundle's Info.plist, which scripts/bundle.sh stamps from
/// Resources/release.env. A value left unset there falls back to a
/// placeholder on pulse.example, so a test build still has somewhere to
/// point. Pulse never opens any of these on its own, only when someone
/// clicks one.
enum ReleaseInfo {
    static var websiteURL: URL { url("PulseWebsiteURL", placeholder: "https://pulse.example") }
    static var privacyPolicyURL: URL { url("PulsePrivacyPolicyURL", placeholder: "https://pulse.example/privacy") }
    static var eulaURL: URL { url("PulseEULAURL", placeholder: "https://pulse.example/eula") }
    /// A help page, if there is one; support is otherwise by email.
    static var supportURL: URL? { string("PulseSupportURL").flatMap(URL.init(string:)) }
    static var supportEmail: String { string("PulseSupportEmail") ?? "support@pulse.example" }
    static var supportMailURL: URL { URL(string: "mailto:\(supportEmail)") ?? websiteURL }

    static var copyright: String { string("NSHumanReadableCopyright") ?? "" }

    /// "0.2.0" and "2", or nil for a bare `swift run`, which has no bundle
    /// of its own.
    static var version: (short: String, build: String?)? {
        guard let short = string("CFBundleShortVersionString") else { return nil }
        return (short, string("CFBundleVersion"))
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.millerroberts.Pulse" }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func url(_ key: String, placeholder: String) -> URL {
        string(key).flatMap(URL.init(string:)) ?? URL(string: placeholder)!
    }
}
