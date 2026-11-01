import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The CLI's own verified session. Keychain access never opens an authorization
/// dialog; an unavailable or locked item falls back to silent sign-in.
public enum TdxCliSessionCache {
    struct Record: Codable {
        let baseURL: String
        let email: String
        let name: String?
        let token: String
        let expiresAt: Date
    }

    private static let service = "com.fleetmate.cli.tdx-session"

    public static func read(baseURL: String, expectedUpn: String?) -> TdxSsoResult? {
        guard let expected = TdxSsoIdentity.normalized(expectedUpn) else { return nil }
        var query = key(baseURL: baseURL, email: expected)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count <= 65_536,
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return validated(record, baseURL: baseURL, expectedUpn: expected, now: Date())
    }

    public static func save(_ result: TdxSsoResult, baseURL: String, expectedUpn: String?) {
        guard let expected = TdxSsoIdentity.normalized(expectedUpn),
              TdxSsoIdentity.verify(result, expectedUpn: expected).success,
              let token = result.token, let expiry = tokenExpiry(token), expiry > Date().addingTimeInterval(30) else { return }
        let record = Record(baseURL: baseURL, email: expected, name: result.userName, token: token, expiresAt: min(expiry, Date().addingTimeInterval(15 * 60)))
        guard let data = try? JSONEncoder().encode(record), data.count <= 65_536 else { return }
        let query = key(baseURL: baseURL, email: expected)
        let values = [kSecValueData as String: data] as [String: Any]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }

    public static func clear(baseURL: String, expectedUpn: String?) {
        guard let expected = TdxSsoIdentity.normalized(expectedUpn) else { return }
        _ = SecItemDelete(key(baseURL: baseURL, email: expected) as CFDictionary)
    }

    static func validated(_ record: Record, baseURL: String, expectedUpn: String?, now: Date) -> TdxSsoResult? {
        guard record.baseURL == baseURL, record.expiresAt > now.addingTimeInterval(30),
              let expiry = tokenExpiry(record.token), expiry > now.addingTimeInterval(30),
              record.expiresAt <= expiry else { return nil }
        let result = TdxSsoIdentity.verify(.success(token: record.token, userName: record.name, userEmail: record.email),
                                           expectedUpn: expectedUpn)
        return result.success ? result : nil
    }

    private static func key(baseURL: String, email: String) -> [String: Any] {
        let digest = SHA256.hash(data: Data((baseURL + "\n" + email).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: digest,
                kSecUseAuthenticationContext as String: context]
    }

    static func tokenExpiry(_ token: String) -> Date? {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3, token.hasPrefix("eyJ") else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = object["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }
}
