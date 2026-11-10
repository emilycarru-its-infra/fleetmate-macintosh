import Foundation
import Security

/// The last TDX sign-in, kept in the login keychain so the next launch — of
/// the app window or the background helper — can reuse it instead of
/// signing in again, which takes up to a minute.
///
/// Cache access is noninteractive for both legacy and modern Keychain items.
/// Each helper uses its parent's cache identity. Protected legacy entries stay
/// untouched and are not read; a fresh verified sign-in populates the current namespace.
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
    /// The address the sign-in was verified for, lowercased.
    public var confirmedUpn: String
    /// The TDX tenant the session belongs to.
    public var baseUrl: String

    public init(token: String, expiry: Date, userId: String?, userName: String?,
                cookies: [HTTPCookie], me: TdxPerson? = nil,
                confirmedUpn: String, baseUrl: String) {
        self.confirmedUpn = confirmedUpn.lowercased()
        self.baseUrl = baseUrl
        self.token = token
        self.expiry = expiry
        self.userId = userId
        self.userName = userName
        self.cookies = cookies.map(Cookie.init)
        self.me = me
    }

    /// Worth reusing: at least an hour left.
    public var isFresh: Bool { expiry > Date().addingTimeInterval(3600) }

    /// Reusable for this sign-in: fresh, for the same tenant, and verified
    /// for the address the app expects now. An unknown expected address
    /// never matches, the same rule the live sign-in applies.
    public func matches(expectedUpn: String?, baseUrl: String?) -> Bool {
        guard isFresh,
              let expected = expectedUpn?.trimmingCharacters(in: .whitespaces).lowercased(),
              !expected.isEmpty,
              let baseUrl, baseUrl == self.baseUrl else { return false }
        return confirmedUpn == expected
    }

    /// The cached "me", only when it is the confirmed person.
    public var confirmedMe: TdxPerson? {
        guard let me, me.primaryEmail?.lowercased() == confirmedUpn else { return nil }
        return me
    }

    private static var service: String {
        "\(AppIdentity.mainBundleIdentifier ?? "ca.ecuad.macadmin.fleetmate").tdx-session.v2"
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
        var result: CFTypeRef?
        guard NoninteractiveKeychain.copyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 1_048_576 else { return nil }
        return try? JSONDecoder().decode(TdxSessionCache.self, from: data)
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self), data.count <= 1_048_576 else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = NoninteractiveKeychain.update(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "TeamDynamix session"
            status = NoninteractiveKeychain.add(add as CFDictionary, nil)
        }
        if status == errSecSuccess { TdxSessionSync.postChanged() }
    }

    public static func clear() {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        NoninteractiveKeychain.delete(match as CFDictionary)
        TdxSessionSync.postChanged()
    }
}
