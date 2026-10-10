import Combine
import Foundation
import FleetMateCore

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
