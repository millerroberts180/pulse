import Foundation
import os
import Security

/// What the old trial left on a Mac that ran it: the days it counted, in
/// UserDefaults and in a login Keychain item ("Pulse trial"), and any licence
/// key, in UserDefaults. Pulse has neither any more, so each launch deletes
/// exactly those, quietly, and nothing else. Once they're gone it finds
/// nothing to do.
enum TrialLeftovers {
    private static let log = Logger(subsystem: "com.millerroberts.Pulse", category: "trial-leftovers")

    static func remove(defaults: UserDefaults = .standard) {
        for key in ["TrialRecord", "LicenseKey"] where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
        // The item is sealed to the build that made it. Another build's delete
        // is refused without asking (errSecInvalidOwnerEdit); the item then
        // stays, holding only dates, and a later launch tries again.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: ReleaseInfo.bundleID,
                                    kSecAttrAccount as String: "trial"]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.debug("Keychain trial item not deleted: \(status)")
        }
    }
}
