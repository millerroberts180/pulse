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
    /// A help page, such as the issue tracker. When there is one, About's
    /// Support link opens it.
    static var supportURL: URL? { string("PulseSupportURL").flatMap(URL.init(string:)) }
    /// The support address, if one is set.
    static var supportEmail: String? { string("PulseSupportEmail") }
    static var supportMailURL: URL { URL(string: "mailto:\(supportEmail ?? placeholderSupportEmail)") ?? websiteURL }
    /// What About's Support link says: the address when there is one,
    /// otherwise the help page's host, as the Website link shows its host.
    /// The placeholder address only when there is neither.
    static var supportTitle: String {
        if let supportEmail { return supportEmail }
        if let supportURL { return supportURL.host() ?? supportURL.absoluteString }
        return placeholderSupportEmail
    }

    /// Where About's links open: the Support link is a mail link only when there is no support page.
    static var linksOpenIn: String { supportURL == nil ? "your browser or mail app" : "your browser" }

    private static let placeholderSupportEmail = "support@pulse.example"

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
