import Foundation

/// An Azure DevOps pull request link that FleetMate's own sign-in can look
/// up: one in the configured organization, written either on the configured
/// server as `https://<server>/<org>/<project>/_git/<repo>/pullrequest/<id>`
/// or in the older form `https://<org>.visualstudio.com/<project>/_git/<repo>/pullrequest/<id>`.
///
/// The Azure DevOps service sends every request to the configured
/// organization, so a link into any other organization is refused here:
/// looking it up would ask the wrong organization for that number.
public struct AzureDevOpsPullRequestLink: Hashable, Sendable {
    public var project: String
    public var repository: String
    public var number: Int

    public init(project: String, repository: String, number: Int) {
        self.project = project
        self.repository = repository
        self.number = number
    }

    /// Matches links against one organization. Cheap and offline, so it can
    /// run on the main actor for every link an agent posts.
    public struct Matcher: Sendable, Equatable {
        /// The organization, compared without case.
        public var organization: String
        /// The configured server's host.
        public var serverHost: String?

        public init(organization: String, serverURL: String?) {
            self.organization = organization
            self.serverHost = serverURL.flatMap { URL(string: $0)?.host?.lowercased() }
        }

        /// A matcher for FleetMate's configuration, or nil when no
        /// organization is set.
        public init?(config: FleetMateConfig) {
            guard let organization = config.devopsOrganization?.trimmingCharacters(in: .whitespaces),
                  !organization.isEmpty else { return nil }
            self.init(organization: organization, serverURL: config.effectiveDevopsBaseUrl)
        }

        public func link(for url: URL) -> AzureDevOpsPullRequestLink? {
            guard url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil, url.port == nil,
                  let host = url.host?.lowercased() else { return nil }
            let org = organization.lowercased()
            let parts = url.path.split(separator: "/").map { ($0.removingPercentEncoding ?? String($0)) }
            guard let git = parts.firstIndex(of: "_git") else { return nil }

            // Where the organization is written: the first path segment on
            // the server, or the subdomain of visualstudio.com.
            let organizationMatches: Bool
            if host == org + ".visualstudio.com" {
                organizationMatches = git == 1
            } else if let serverHost, host == serverHost {
                organizationMatches = git == 2 && parts[0].lowercased() == org
            } else {
                organizationMatches = false
            }
            guard organizationMatches,
                  case .pullRequest(.azureDevOps(let project, let repo), let number)? = try? FleetMateLink.parseWeb(url),
                  number > 0 else { return nil }
            return AzureDevOpsPullRequestLink(project: project, repository: repo, number: number)
        }
    }
}
