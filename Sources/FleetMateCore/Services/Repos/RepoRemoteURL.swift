import Foundation

/// Parses git remote URLs into a `RepoKey`, so a local checkout can be matched
/// to a catalog entry however its origin was written.
///
/// Azure DevOps is recognised by the shape of the path rather than by host,
/// because the host is configuration (`devops_base_url`), never code:
/// - https: `https://[user@]<host>/<org>/<project>/_git/<repo>`
/// - legacy https: `https://<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>`
/// - ssh: `git@<ssh-host>:v3/<org>/<project>/<repo>`
/// - the `/<org>/_git/<repo>` short form, used when a repository has its
///   project's name, resolves the project to the repository name.
///
/// GitHub: `https://github.com/<owner>/<repo>[.git]`, `git@github.com:<owner>/<repo>.git`
/// and `ssh://git@github.com/<owner>/<repo>.git`.
///
/// Anything else becomes `.other`, keyed by host and path. Case, a `.git`
/// suffix, credentials, ports and percent-encoding never change the key.
public enum RepoRemoteURL {

    public static func parse(_ raw: String) -> RepoKey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A local remote (a bare repository on disk) keys by its path.
        if trimmed.hasPrefix("/") || trimmed.lowercased().hasPrefix("file://") {
            var path = trimmed.lowercased().hasPrefix("file://") ? String(trimmed.dropFirst("file://".count)) : trimmed
            path = path.removingPercentEncoding ?? path
            while path.hasSuffix("/") { path.removeLast() }
            if path.lowercased().hasSuffix(".git") { path = String(path.dropLast(4)) }
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last else { return nil }
            return RepoKey(provider: .other, owner: "/" + parts.dropLast().joined(separator: "/"), name: name)
        }
        guard let (host, path, isScp) = split(trimmed) else { return nil }
        var segments = path.split(separator: "/").map { decode(String($0)) }.filter { !$0.isEmpty }
        if let last = segments.last, last.lowercased().hasSuffix(".git") {
            segments[segments.count - 1] = String(last.dropLast(4))
        }
        guard !segments.isEmpty else { return nil }
        let lowerHost = host.lowercased()

        if lowerHost == "github.com" || lowerHost == "www.github.com" {
            guard segments.count == 2 else { return nil }
            return RepoKey(provider: .gitHub, owner: segments[0], name: segments[1])
        }

        // Azure DevOps ssh: v3/<org>/<project>/<repo>
        if segments.count == 4, segments[0].lowercased() == "v3", isScp || lowerHost.hasPrefix("ssh.") || lowerHost.hasPrefix("vs-ssh.") {
            return RepoKey(provider: .azureDevOps, owner: segments[1], project: segments[2], name: segments[3])
        }

        // Azure DevOps https, any host: the path carries a `_git` segment.
        if let gitIndex = segments.firstIndex(where: { $0.lowercased() == "_git" }), gitIndex + 1 == segments.count - 1 {
            let repo = segments[gitIndex + 1]
            var before = Array(segments[..<gitIndex])
            if lowerHost.hasSuffix(".visualstudio.com") {
                // Legacy: the organization is the subdomain.
                if before.first?.lowercased() == "defaultcollection" { before.removeFirst() }
                let org = String(host.dropLast(".visualstudio.com".count))
                switch before.count {
                case 0: return RepoKey(provider: .azureDevOps, owner: org, project: repo, name: repo)
                case 1: return RepoKey(provider: .azureDevOps, owner: org, project: before[0], name: repo)
                default: break
                }
            } else {
                switch before.count {
                case 1: return RepoKey(provider: .azureDevOps, owner: before[0], project: repo, name: repo)
                case 2: return RepoKey(provider: .azureDevOps, owner: before[0], project: before[1], name: repo)
                default: break
                }
            }
        }

        return RepoKey(provider: .other, owner: lowerHost, name: segments.joined(separator: "/"))
    }

    /// The registry id for a remote URL, or nil if it cannot be parsed.
    public static func id(for raw: String) -> String? { parse(raw)?.id }

    // MARK: - Private

    /// Splits a URL or scp-style address into host and path, dropping any
    /// user, password and port.
    private static func split(_ raw: String) -> (host: String, path: String, isScp: Bool)? {
        guard !raw.isEmpty else { return nil }
        if raw.contains("://") {
            guard let components = URLComponents(string: raw.replacingOccurrences(of: " ", with: "%20")),
                  let host = components.host, !host.isEmpty else { return nil }
            return (host, components.percentEncodedPath, false)
        }
        // scp-like: [user@]host:path
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        var host = String(raw[..<colon])
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        guard !host.isEmpty, !host.contains("/") else { return nil }
        return (host, String(raw[raw.index(after: colon)...]), true)
    }

    private static func decode(_ segment: String) -> String {
        segment.removingPercentEncoding ?? segment
    }
}
