import AppKit
import Combine
import Foundation
import FleetMateCore
import AgentsMate

/// What the agent terminal needs to know about the rest of the app: where a
/// session should start and what to tell it about where it is.
extension AppState {

    /// Hand the terminal store its context sources, and rewrite
    /// `$FLEETMATE_CONTEXT` whenever the segment, the selected repository or
    /// pull request, or a sign-in changes. Safe to call more than once.
    func wireAgentTerminal() {
        guard terminals.whereabouts == nil else { return }
        terminals.whereabouts = { [weak self] directory in
            self?.agentWhereabouts(workingDirectory: directory) ?? AgentWhereabouts(module: "FleetMate", workingDirectory: directory)
        }
        terminals.startDirectory = { [weak self] in
            self?.agentStartDirectory() ?? AgentTerminalStore.workspaceDirectory()
        }
        terminals.updateLaneFolders()
        terminals.showRepos = { [weak self] in
            guard let self else { return }
            self.terminals.hide()
            self.selectedTab = .development
            self.development.segment = .repos
        }
        // A pull request chip in the Agent Inbox opens in the lightbox, as a
        // pull request link anywhere else in FleetMate does.
        terminals.lanes.onOpenPullRequest = { [weak self] url in
            self?.openPullRequestFromAgent(url)
        }
        // A link clicked in a session's terminal that FleetMate has a view
        // for opens in the lightbox; anything else goes to the system.
        terminals.lanes.onOpenLink = { [weak self] url, _ in
            self?.openTerminalLink(url) ?? false
        }

        // Azure DevOps pull requests the agents post are looked up with the
        // app's own Azure DevOps sign-in, in the configured organization only.
        terminals.pullRequestSource.matcher = AzureDevOpsPullRequestLink.Matcher(config: config)
        terminals.pullRequestSource.fetch = { [weak self] link in
            guard let self, await self.devOpsService.ensureValidToken() else {
                throw PullRequestResolverError.noAnswer
            }
            return try await self.devOpsService.getUnifiedPullRequest(project: link.project,
                                                                      repository: link.repository,
                                                                      id: link.number)
        }
        $config
            .map { AzureDevOpsPullRequestLink.Matcher(config: $0) }
            .removeDuplicates()
            .sink { [weak self] in self?.terminals.pullRequestSource.matcher = $0 }
            .store(in: &terminals.subscriptions)
        let changes: [AnyPublisher<Void, Never>] = [
            development.$segment.map { _ in () }.eraseToAnyPublisher(),
            development.$selectedPullRequest.map { _ in () }.eraseToAnyPublisher(),
            development.repos.$selectedId.map { _ in () }.eraseToAnyPublisher(),
            authManager.$systems.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .repoRegistryChanged).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.writeAgentContext() }
            .store(in: &terminals.subscriptions)
    }

    /// Open a link from a session's terminal in the lightbox over the main
    /// window, hiding the Agent dock so it is in view. Returns false for a
    /// link FleetMate has no view for, which then opens in its default app.
    func openTerminalLink(_ url: URL) -> Bool {
        guard let link = try? FleetMateLink.parseWeb(url), link.opensInLightbox else { return false }
        terminals.hide()
        NSApplication.shared.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
        openLightbox(link)
        return true
    }

    /// Show a pull request an agent posted: in the lightbox over the main
    /// window when FleetMate has a view for it, otherwise in the browser.
    func openPullRequestFromAgent(_ url: URL) {
        guard let link = try? FleetMateLink.parseWeb(url), link.opensInLightbox else {
            NSWorkspace.shared.open(BrowserLink.forBrowser(url))
            return
        }
        NSApplication.shared.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
        openLightbox(link)
    }

    func writeAgentContext() {
        AgentContextWriter.write(agentWhereabouts(workingDirectory: nil), to: terminals.contextPath)
    }

    /// Where a new session opens when nothing chose a folder: the selected
    /// repository's checkout while Repos is on screen, else the folder
    /// repositories are cloned into, else FleetMate's own folder. Never the
    /// bare home folder, which tells an agent nothing.
    func agentStartDirectory() -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if selectedTab == .development, development.segment == .repos,
           let path = development.repos.selectedPath,
           fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
        return AgentTerminalStore.workspaceDirectory()
    }

    func agentWhereabouts(workingDirectory: String?) -> AgentWhereabouts {
        var segment: String?
        var selection = agentSelection.map {
            AgentWhereabouts.Selection(kind: $0.kind, id: $0.id, title: $0.title, fields: $0.fields)
        }
        if selectedTab == .development {
            segment = development.segment.rawValue
            switch development.segment {
            case .repos:
                if let repo = development.repos.selected {
                    var fields: [String: String] = [:]
                    fields["path"] = repo.local?.path
                    fields["remote"] = (repo.local?.remoteUrl ?? repo.catalog?.cloneUrl)
                        .map(AgentWhereabouts.redactRemote)
                    fields["defaultBranch"] = repo.defaultBranch
                    selection = .init(kind: "repository", id: repo.key.id, title: repo.key.displayName,
                                      fields: fields.compactMapValues { $0 })
                }
            case .pullRequests:
                if let pr = development.selectedPullRequest {
                    selection = .init(kind: "pullRequest", id: "\(pr.repository)#\(pr.number)", title: pr.title,
                                      fields: ["repository": "\(pr.container)/\(pr.repository)",
                                               "sourceBranch": pr.sourceBranch, "targetBranch": pr.targetBranch,
                                               "url": pr.webUrl, "author": pr.authorName])
                }
            default:
                break
            }
        }
        return AgentWhereabouts(
            module: selectedTab.rawValue,
            segment: segment,
            selection: selection,
            workingDirectory: workingDirectory,
            trackedRepositories: Self.trackedRepositories(),
            backends: agentBackends()
        )
    }

    /// The tracked checkouts, read from the registry the CLI shares.
    static func trackedRepositories() -> [AgentWhereabouts.Repository] {
        guard let document = try? RepoRegistryStore().load() else { return [] }
        return document.trackedEntries.map {
            AgentWhereabouts.Repository(name: $0.key.displayName, path: $0.path,
                                        remote: $0.remoteUrl, defaultBranch: $0.defaultBranch)
        }
    }

    /// Every configured system and whether it is signed in. Account names,
    /// failure detail and anything token-like stay out: an agent needs to
    /// know a sign-in is missing, not whose it is or why.
    func agentBackends() -> [AgentWhereabouts.Backend] {
        authManager.systems.values
            .sorted { $0.systemId.displayName < $1.systemId.displayName }
            .compactMap { status in
                let state: String
                switch status.state {
                case .notConfigured: return nil
                case .valid: state = "signed in"
                case .configured: state = "configured, not yet checked"
                case .authenticating: state = "signing in"
                case .expired: state = "sign-in expired"
                case .failed: state = "not signed in"
                case .servicePrincipal: state = "signed in as a service principal"
                }
                return AgentWhereabouts.Backend(system: status.systemId.displayName, state: state)
            }
    }
}
