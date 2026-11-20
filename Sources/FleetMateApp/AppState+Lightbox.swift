import SwiftUI
import FleetMateCore

/// The app's one link router and the lightbox it opens.
///
/// Every in-app link ends up here: a `fleetmate://` URL from the system (a
/// browser page, a chat message, a link clicked in the Agent terminal, which
/// SwiftTerm hands to the system), a search hit, a dashboard row, or a link
/// clicked inside the lightbox itself. Work items, issues, pull requests,
/// commits and pipeline runs open in the lightbox; devices, assets, tickets,
/// people and Reporting pages open in their tab.
extension AppState {

    /// Show what `link` names, in the lightbox when it has a view for it,
    /// otherwise in its tab.
    func follow(_ link: FleetMateLink) {
        if link.opensInLightbox {
            openLightbox(link)
            return
        }
        closeLightbox()
        switch link {
        case .device(let id):
            navigateToDeviceId = id
            navigateToTab = .devices
        case .asset(let id):
            navigateToAssetId = id
            navigateToTab = .inventory
        case .ticket(let id):
            navigateToTicketId = id
            navigateToTab = .tickets
        case .user, .group:
            navigateToTab = .identity
        case .reporting(let target):
            reporting.open(target)
            navigateToTab = .reporting
        case .workItem, .gitHubIssue, .pullRequest, .commit, .azureDevOpsRun, .azureDevOpsPipeline, .gitHubRun:
            break // Opened in the lightbox above.
        }
    }

    // MARK: Lightbox

    /// Present the lightbox on `link`, or, when it is already up, add `link`
    /// to its trail.
    func openLightbox(_ link: FleetMateLink) {
        collapseAgentDock(for: .inApp)
        if lightboxHistory == nil {
            lightboxHistory = LightboxHistory(link)
        } else {
            lightboxHistory?.push(link)
        }
    }

    func closeLightbox() {
        if lightboxHistory != nil { lightboxHistory = nil }
    }

    func showLightboxCrumb(at position: Int) {
        lightboxHistory?.go(to: position)
    }

    /// Close the lightbox and show `link` in the tab it lives in, with the
    /// list around it.
    func openInHomeTab(_ link: FleetMateLink) {
        closeLightbox()
        switch link {
        case .workItem(let id):
            navigateToWorkItemId = id
            navigateToTab = .projects
        case .gitHubIssue(let owner, let repo, let number):
            navigateToGitHubIssueUrl = "https://github.com/\(owner)/\(repo)/issues/\(number)"
            navigateToTab = .projects
        case .pullRequest, .commit, .azureDevOpsRun, .azureDevOpsPipeline, .gitHubRun:
            pendingDevelopmentLink = link
            navigateToTab = .development
        case .device, .asset, .ticket, .user, .group, .reporting:
            follow(link)
        }
    }

    /// A link clicked inside the lightbox: anything it can show is added to
    /// its trail, any other `fleetmate://` link goes to its tab, and web pages
    /// FleetMate has no view for open in the browser.
    func lightboxOpenURL(_ url: URL) -> OpenURLAction.Result {
        let scheme = url.scheme?.lowercased()
        if scheme == FleetMateLink.scheme || scheme == AppEdition.current.linkScheme {
            guard let link = try? FleetMateLink.parse(url) else { return .discarded }
            follow(link)
            return .handled
        }
        if scheme == "http" || scheme == "https" {
            if let link = try? FleetMateLink.parseWeb(url), link.opensInLightbox {
                openLightbox(link)
                return .handled
            }
            collapseAgentDock(for: .outsideApp)
            return .systemAction(BrowserLink.forBrowser(url))
        }
        return .systemAction(url)
    }

    /// A short name for a crumb: the item's title when a list already holds
    /// it, otherwise its id.
    func lightboxTitle(for link: FleetMateLink) -> String {
        switch link {
        case .workItem(let id):
            let cached = (cachedMyWorkItems + cachedWorkItems).first { $0.id == id }?.fields?.title
            return cached.map { "#\(id) \($0)" } ?? "Work item #\(id)"
        case .gitHubIssue(_, let repo, let number):
            return "\(repo) #\(number)"
        case .pullRequest(let host, let number):
            let repo = host.repositoryName
            let cached: UnifiedPullRequest? = development.queue.pullRequests
                .first { $0.number == number && $0.repository == repo }
            if let cached { return "!\(number) \(cached.title)" }
            return "\(repo) !\(number)"
        case .commit(let host, let sha):
            return "\(host.repositoryName) \(sha.prefix(7))"
        case .azureDevOpsRun(_, let runId), .gitHubRun(_, _, let runId):
            let cached = development.pipelineRuns.first { $0.runId == runId }
            return cached.map { "\($0.pipelineName) \($0.runNumber)" } ?? "Run \(runId)"
        case .azureDevOpsPipeline(_, let definitionId):
            return "Pipeline \(definitionId)"
        case .device, .asset, .ticket, .user, .group, .reporting:
            return link.url.absoluteString
        }
    }

    // MARK: Agent dock

    /// Get the Agent terminal out of the way of what a followed link shows.
    func collapseAgentDock(for target: AgentDockLinkRule.Target) {
        if AgentDockLinkRule.hidesDock(dockShowing: terminals.isShowing, target: target) {
            terminals.hide()
        }
    }
}

extension FleetMateLink.Host {
    var repositoryName: String {
        switch self {
        case .azureDevOps(_, let repo), .gitHub(_, let repo): return repo
        }
    }
}

// MARK: - Environment

/// Opens the lightbox from any view: `lightbox.open(.workItem(id: 7264))`.
/// ContentView installs the real one; outside the main window it does nothing.
struct LightboxAction {
    fileprivate let handler: @MainActor (FleetMateLink) -> Void

    init(_ handler: @escaping @MainActor (FleetMateLink) -> Void) {
        self.handler = handler
    }

    @MainActor func open(_ link: FleetMateLink) { handler(link) }
    @MainActor func callAsFunction(_ link: FleetMateLink) { handler(link) }
}

private struct LightboxActionKey: EnvironmentKey {
    static let defaultValue = LightboxAction { _ in }
}

extension EnvironmentValues {
    var lightbox: LightboxAction {
        get { self[LightboxActionKey.self] }
        set { self[LightboxActionKey.self] = newValue }
    }
}
