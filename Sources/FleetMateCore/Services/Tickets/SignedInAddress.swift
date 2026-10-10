import Foundation

/// The address of the work account the Mac's user is signed in with, read from
/// the device rather than asked of anyone. The TeamDynamix identity check
/// refuses a sign-in when it has no address to compare against, so no single
/// source may be the only one:
///
/// 1. Platform SSO (`app-sso platform -s`): the on-premises Kerberos ticket's
///    UPN, then the cloud Kerberos ticket's (`name\@DOMAIN@KERBEROS.MICROSOFTONLINE.COM`),
///    then `loginUserName` when it is not masked. A cloud-only Mac has no
///    on-premises ticket, and `loginUserName` is often masked (`a***e@example.edu`).
/// 2. The Kerberos SSO extension's principal for each configured realm.
/// 3. The Microsoft account Office and Company Portal were activated with.
///
/// The app tries its own Entra identity (Azure DevOps, the Azure CLI) between
/// the device sources and Office.
public enum SignedInAddress {
    /// A trimmed, lower-cased address, or nil for anything that is not one,
    /// including a masked address.
    public static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty,
              trimmed.contains("@"),
              !trimmed.contains("*"),
              !trimmed.contains("\\"),
              !trimmed.contains(" ")
        else { return nil }
        return trimmed
    }

    /// The address in `app-sso platform -s` output, best source first.
    public static func fromPlatformSso(_ output: String) -> String? {
        var onPremises: String?
        var cloud: String?
        var login: String?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let value = quotedValue(trimmed) else { continue }
            if trimmed.hasPrefix("\"upn\"") || trimmed.hasPrefix("upn") {
                if value.uppercased().hasSuffix("@KERBEROS.MICROSOFTONLINE.COM") {
                    cloud = cloud ?? fromCloudKerberos(value)
                } else {
                    onPremises = onPremises ?? normalized(value)
                }
            } else if trimmed.hasPrefix("\"loginUserName\"") || trimmed.hasPrefix("loginUserName") {
                login = login ?? normalized(value)
            }
        }
        return onPremises ?? cloud ?? login
    }

    /// `name\@DOMAIN@KERBEROS.MICROSOFTONLINE.COM` (as `app-sso` prints it, with
    /// the backslash itself escaped) → `name@domain`.
    public static func fromCloudKerberos(_ principal: String) -> String? {
        let upper = principal.uppercased()
        guard let realm = upper.range(of: "@KERBEROS.MICROSOFTONLINE.COM", options: .backwards) else { return nil }
        let name = String(principal[..<realm.lowerBound])
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\@", with: "@")
        return normalized(name)
    }

    /// The first address-looking value under a `upn` or principal key in an
    /// `app-sso -i <realm> -j` answer.
    public static func fromKerberosRealm(_ json: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: json) else { return nil }
        return principal(in: object)
    }

    private static func principal(in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                let k = key.lowercased()
                if k.contains("upn") || k.contains("principal") || k == "username" || k == "user_name",
                   let address = normalized(value as? String) {
                    return address
                }
            }
            for value in dict.values {
                if let found = principal(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = principal(in: value) { return found }
            }
        }
        return nil
    }

    private static func quotedValue(_ line: String) -> String? {
        guard let colon = line.range(of: ":") ?? line.range(of: "=") else { return nil }
        let rest = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("\"") else { return nil }
        let inner = rest.dropFirst()
        guard let end = inner.lastIndex(of: "\"") else { return nil }
        return String(inner[..<end])
    }

    // MARK: - Reading the device

    /// Platform SSO, from `app-sso platform -s`. Blocking; call off the main thread.
    public static func readPlatformSso() -> String? {
        let result = ProcessRunner.runSync("/usr/bin/app-sso", ["platform", "-s"])
        guard result.exitCode == 0 else { return nil }
        return fromPlatformSso(result.stdout)
    }

    /// The Kerberos SSO extension's principal. Blocking; call off the main thread.
    public static func readKerberosExtension() -> String? {
        let list = ProcessRunner.runSync("/usr/bin/app-sso", ["-l", "-j"])
        guard list.exitCode == 0,
              let data = list.stdout.data(using: .utf8),
              let realms = (try? JSONSerialization.jsonObject(with: data)) as? [String]
        else { return nil }
        for realm in realms where !realm.isEmpty {
            let info = ProcessRunner.runSync("/usr/bin/app-sso", ["-i", realm, "-j"])
            if info.exitCode == 0, let json = info.stdout.data(using: .utf8),
               let address = fromKerberosRealm(json) {
                return address
            }
        }
        return nil
    }

    /// The account Office (and with it Company Portal's Entra registration) was activated with.
    public static func readMicrosoftAccount() -> String? {
        for (key, domain) in [
            ("OfficeActivationEmailAddress", "com.microsoft.office"),
            ("UserPrincipalName", "com.microsoft.CompanyPortalMac"),
        ] {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String,
               let address = normalized(value) {
                return address
            }
        }
        return nil
    }

    /// The device sources in order: Platform SSO, then the Kerberos SSO extension.
    /// Blocking; call off the main thread.
    public static func readDevice() -> (address: String, source: String)? {
        if let address = readPlatformSso() { return (address, "Platform SSO") }
        if let address = readKerberosExtension() { return (address, "Kerberos SSO extension") }
        return nil
    }
}
