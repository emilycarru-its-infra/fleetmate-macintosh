import Foundation

/// Lists every repository the signed-in user can see: all projects of the
/// configured Azure DevOps organization, and on GitHub the user's own
/// repositories, those of every organization they belong to, plus any extra
/// owners configured.
///
/// Azure DevOps reuses `AzureDevOpsService` and whatever token its owner gave
/// it. GitHub resolves a token from config, then `gh auth token`, then
/// `GITHUB_TOKEN`/`GH_TOKEN` — never the Keychain.
public struct RepoCatalogService {
    public typealias GitHubTokenProvider = @Sendable () async -> String?

    private let azureDevOps: AzureDevOpsService?
    private let azureDevOpsOrganization: String?
    private let gitHubToken: GitHubTokenProvider?
    private let gitHubOwners: [String]
    private let session: URLSession

    /// - Parameters:
    ///   - azureDevOps: a service already holding a token, or nil to skip Azure DevOps.
    ///   - azureDevOpsOrganization: the organization name, used in repository keys.
    ///   - gitHubToken: token source, or nil to skip GitHub.
    ///   - gitHubOwners: owners to list beyond the user's own memberships.
    public init(
        azureDevOps: AzureDevOpsService?,
        azureDevOpsOrganization: String?,
        gitHubToken: GitHubTokenProvider?,
        gitHubOwners: [String] = [],
        session: URLSession = .shared
    ) {
        self.azureDevOps = azureDevOps
        self.azureDevOpsOrganization = azureDevOpsOrganization
        self.gitHubToken = gitHubToken
        self.gitHubOwners = gitHubOwners
        self.session = session
    }

    /// Token resolution for GitHub without the Keychain: config token, then
    /// the `gh` CLI, then the environment.
    public static func gitHubTokenProvider(config: GitHubProviderConfig?) -> GitHubTokenProvider {
        let configured = config?.token
        let useGh = config?.useGhCli ?? true
        return {
            if let configured, !configured.isEmpty { return configured }
            if useGh, let token = await ProcessRunner.trimmedOutput("gh", ["auth", "token"]) { return token }
            let env = ProcessInfo.processInfo.environment
            if let token = env["GITHUB_TOKEN"] ?? env["GH_TOKEN"], !token.isEmpty { return token }
            return nil
        }
    }

    /// Fetches both providers concurrently. A provider that fails contributes
    /// an error message, never an exception.
    public func fetch() async -> RepoCatalog {
        async let azure = fetchAzureDevOps()
        async let github = fetchGitHub()
        let (a, g) = await (azure, github)
        var catalog = RepoCatalog(repos: a.repos + g.repos, errors: a.errors + g.errors)
        // The same repository can arrive through two owners; keep one.
        var seen = Set<String>()
        catalog.repos = catalog.repos.filter { seen.insert($0.id).inserted }.sorted { $0.key < $1.key }
        return catalog
    }

    // MARK: - Azure DevOps

    func fetchAzureDevOps() async -> (repos: [CatalogRepo], errors: [String]) {
        guard let service = azureDevOps else { return ([], []) }
        guard service.isConfigured, let org = azureDevOpsOrganization, !org.isEmpty else {
            return ([], ["Azure DevOps: no organization configured"])
        }
        guard await service.ensureValidToken() else {
            return ([], ["Azure DevOps: not signed in (run 'az login')"])
        }
        let projects: [DevOpsProject]
        do {
            projects = try await service.listProjects()
        } catch {
            return ([], ["Azure DevOps: \(error.localizedDescription)"])
        }

        var repos: [CatalogRepo] = []
        var errors: [String] = []
        // Sequential: AzureDevOpsService is a class with mutable token state,
        // and project counts are small enough that this stays quick.
        for project in projects {
            do {
                let list = try await service.getRepositories(project: project.name)
                repos += list.compactMap { Self.catalogRepo(from: $0, organization: org, project: project.name) }
            } catch {
                errors.append("Azure DevOps \(project.name): \(error.localizedDescription)")
            }
        }
        return (repos, errors)
    }

    static func catalogRepo(from repo: GitRepository, organization: String, project: String) -> CatalogRepo? {
        if repo.isDisabled == true { return nil }
        let projectName = repo.project?.name ?? project
        // Prefer the key the clone URL itself parses to, so a catalog entry and
        // a checkout of it always share an id.
        let parsed = repo.remoteUrl.flatMap(RepoRemoteURL.parse)
        let key = parsed?.provider == .azureDevOps
            ? parsed!
            : RepoKey(provider: .azureDevOps, owner: organization, project: projectName, name: repo.name)
        guard let cloneUrl = repo.remoteUrl ?? repo.webUrl else { return nil }
        return CatalogRepo(
            key: key,
            cloneUrl: Self.stripUser(cloneUrl),
            sshUrl: repo.sshUrl,
            webUrl: repo.webUrl,
            defaultBranch: repo.defaultBranch
        )
    }

    /// Azure DevOps returns `https://<org>@host/...`; the user part would pin
    /// git's credential lookup to the org name, so drop it.
    static func stripUser(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.user != nil else { return url }
        components.user = nil
        components.password = nil
        return components.string ?? url
    }

    // MARK: - GitHub

    struct GitHubRepo: Decodable {
        let name: String
        let owner: Owner
        let clone_url: String
        let ssh_url: String?
        let html_url: String?
        let default_branch: String?
        let archived: Bool?
        let fork: Bool?
        let `private`: Bool?
        struct Owner: Decodable { let login: String }
    }

    func fetchGitHub() async -> (repos: [CatalogRepo], errors: [String]) {
        guard let provider = gitHubToken else { return ([], []) }
        guard let token = await provider() else {
            return ([], ["GitHub: no token (run 'gh auth login')"])
        }

        var repos: [GitHubRepo] = []
        var errors: [String] = []
        do {
            repos += try await paged("https://api.github.com/user/repos?per_page=100&affiliation=owner,collaborator,organization_member", token: token)
        } catch {
            errors.append("GitHub: \(error.localizedDescription)")
        }

        let covered = Set(repos.map { $0.owner.login.lowercased() })
        for owner in gitHubOwners where !covered.contains(owner.lowercased()) {
            let encoded = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? owner
            do {
                repos += try await paged("https://api.github.com/orgs/\(encoded)/repos?per_page=100&type=all", token: token)
            } catch {
                // Not an organization: try it as a user.
                do {
                    repos += try await paged("https://api.github.com/users/\(encoded)/repos?per_page=100", token: token)
                } catch {
                    errors.append("GitHub \(owner): \(error.localizedDescription)")
                }
            }
        }

        let catalog = repos.map {
            CatalogRepo(
                key: RepoKey(provider: .gitHub, owner: $0.owner.login, name: $0.name),
                cloneUrl: $0.clone_url,
                sshUrl: $0.ssh_url,
                webUrl: $0.html_url,
                defaultBranch: $0.default_branch,
                isArchived: $0.archived ?? false,
                isFork: $0.fork ?? false,
                isPrivate: $0.private
            )
        }
        return (catalog, errors)
    }

    private func paged(_ first: String, token: String) async throws -> [GitHubRepo] {
        var next: URL? = URL(string: first)
        var all: [GitHubRepo] = []
        var pages = 0
        while let url = next, pages < 50 {
            pages += 1
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, response) = try await session.loggedData(for: request, service: "GitHub")
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200...299).contains(http.statusCode) else {
                throw RepoError.gitFailed(command: "GitHub API", message: "HTTP \(http.statusCode) for \(url.path)")
            }
            all += try JSONDecoder().decode([GitHubRepo].self, from: data)
            next = Self.nextLink(http.value(forHTTPHeaderField: "Link"))
        }
        return all
    }

    /// The `rel="next"` URL of a GitHub `Link` header.
    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains("rel=\"next\"") else { continue }
            let target = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: target)
        }
        return nil
    }
}
