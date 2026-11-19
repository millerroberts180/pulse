/// Which other apps' audio asks Pulse to be quiet.
public enum QuietRules {
    /// System sounds, speech, and accessibility voices never count as media:
    /// an alert shouldn't hush typing, and VoiceOver's own voice must not
    /// silence the cues meant to accompany it.
    public static func isIgnoredAudioSource(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        if ["systemsoundserverd", "com.apple.powerchime", "com.apple.systemuiserver", "com.apple.notificationcenterui"].contains(id) {
            return true
        }
        return ["speech", "voiceover", "universalaccess", "accessibility"].contains { id.contains($0) }
    }
}
