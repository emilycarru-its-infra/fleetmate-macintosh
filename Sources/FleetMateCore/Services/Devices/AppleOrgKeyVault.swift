import Foundation

/// Where one Apple School or Business Manager organization's API credentials
/// live: three secrets in an Azure Key Vault, read with the operator's own
/// `az` sign-in. Nothing is stored on the Mac, so there is no Keychain item
/// to prompt for.
///
/// The secrets are `<prefix>ClientId`, `<prefix>KeyId` and
/// `<prefix>PrivateKeyPem`. Each prefix is one organization.
public struct AppleOrgSource: Hashable, Sendable {
    public let vault: String
    public let prefix: String

    /// The organization's profile name, used to tell organizations apart.
    public var name: String { prefix }
    public var clientIdSecret: String { "\(prefix)ClientId" }
    public var keyIdSecret: String { "\(prefix)KeyId" }
    public var privateKeySecret: String { "\(prefix)PrivateKeyPem" }

    public static let defaultPrefix = "Asbm"

    public init(vault: String, prefix: String = AppleOrgSource.defaultPrefix) {
        self.vault = vault
        self.prefix = prefix
    }
}

/// Reads Key Vault secrets with `az keyvault secret show`, as the operator.
public enum AppleOrgKeyVault {
    /// How long one `az` call may take before the read is abandoned.
    static let timeout: Duration = .seconds(30)

    public static func secret(_ name: String, in vault: String,
                              run: (@Sendable ([String]) async -> ProcessOutput)? = nil) async throws -> String {
        let args = ["keyvault", "secret", "show", "--vault-name", vault, "--name", name, "--query", "value", "-o", "tsv"]
        let runner = run ?? { args in await ProcessRunner.run(AzTokenSource.locateAz(), args) }
        guard let r = await FirstOf.value(within: timeout, { await runner(args) }) else {
            throw AppleOrgError.keyVault(name, "az did not answer within \(timeout.components.seconds) seconds")
        }
        guard r.exitCode == 0 else {
            throw AppleOrgError.keyVault(name, (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppleOrgError.keyVault(name, "the secret is empty") }
        return value
    }

    /// A PEM key as Apple's signing code expects it. A key stored as a single
    /// line (newlines turned into spaces or literal `\n` by a variable group)
    /// is rebuilt with its header, footer and 64-character body lines.
    public static func normalizedPEM(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let begin = text.range(of: #"-----BEGIN [A-Z ]+-----"#, options: .regularExpression),
              let end = text.range(of: #"-----END [A-Z ]+-----"#, options: .regularExpression),
              begin.upperBound <= end.lowerBound else { return text }
        let body = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        var lines = [String(text[begin])]
        var rest = Substring(body)
        while !rest.isEmpty {
            lines.append(String(rest.prefix(64)))
            rest = rest.dropFirst(64)
        }
        lines.append(String(text[end]))
        return lines.joined(separator: "\n") + "\n"
    }
}
