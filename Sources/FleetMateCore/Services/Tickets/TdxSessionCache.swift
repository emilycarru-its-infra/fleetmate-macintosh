import Foundation
import Security

/// The last TDX sign-in, kept in the login keychain so the next launch — of
/// the app window or the background helper — can reuse it instead of
/// signing in again, which takes up to a minute.
///
/// Both processes are the same signed binary, so either can read what the
/// other wrote without a keychain prompt.
public struct TdxSessionCache: Codable, Sendable {
    public struct Cookie: Codable, Sendable {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String
        public let expires: Date?
        public let isSecure: Bool

        public init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            isSecure = cookie.isSecure
        }

        public var httpCookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
            ]
            if let expires { properties[.expires] = expires }
            if isSecure { properties[.secure] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }

    public var token: String
    public var expiry: Date
    public var userId: String?
    public var userName: String?
    public var cookies: [Cookie]
    public var me: TdxPerson?

    public init(token: String, expiry: Date, userId: String?, userName: String?,
                cookies: [HTTPCookie], me: TdxPerson? = nil) {
        self.token = token
        self.expiry = expiry
        self.userId = userId
        self.userName = userName
        self.cookies = cookies.map(Cookie.init)
        self.me = me
    }

    /// Worth reusing: at least an hour left.
    public var isFresh: Bool { expiry > Date().addingTimeInterval(3600) }

    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "ca.ecuad.macadmin.fleetmate").tdx-session"
    }
    private static let account = "session"

    public static func load() -> TdxSessionCache? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TdxSessionCache.self, from: data)
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "TeamDynamix session"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func clear() {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
    }
}
