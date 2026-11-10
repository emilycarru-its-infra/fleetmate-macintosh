import Foundation
import LocalAuthentication
import Security

/// App-owned credentials never authorize themselves through a password or biometric dialog.
/// An inaccessible item remains protected and is reported to the caller as unavailable.
public enum NoninteractiveKeychain {
    static func query(_ attributes: CFDictionary) -> CFDictionary {
        var query = attributes as! [String: Any]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query as CFDictionary
    }

    private static func disableLegacyInteraction() -> Bool {
        // LAContext covers modern items. Existing login-Keychain ACLs also need this
        // legacy switch; do not restore interactive behavior after an operation.
        SecKeychainSetUserInteractionAllowed(false) == errSecSuccess
    }

    @discardableResult
    public static func copyMatching(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard disableLegacyInteraction() else { return errSecInteractionNotAllowed }
        return SecItemCopyMatching(query(attributes), result)
    }

    @discardableResult
    public static func update(_ attributes: CFDictionary, _ values: CFDictionary) -> OSStatus {
        guard disableLegacyInteraction() else { return errSecInteractionNotAllowed }
        return SecItemUpdate(query(attributes), values)
    }

    @discardableResult
    public static func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard disableLegacyInteraction() else { return errSecInteractionNotAllowed }
        return SecItemAdd(query(attributes), result)
    }

    @discardableResult
    public static func delete(_ attributes: CFDictionary) -> OSStatus {
        guard disableLegacyInteraction() else { return errSecInteractionNotAllowed }
        return SecItemDelete(query(attributes))
    }
}
