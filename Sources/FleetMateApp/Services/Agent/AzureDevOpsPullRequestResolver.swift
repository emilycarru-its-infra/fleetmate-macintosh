import Foundation
import AgentsMate
import FleetMateCore

/// Looks up the Azure DevOps pull requests agents post, through FleetMate's
/// own Azure DevOps service and sign-in, so their chips in the inbox and the
/// session rows show state and title. No token or secret of its own: a link
/// is answered only while FleetMate is signed in to Azure DevOps.
///
/// The ledger is built when the terminal store is, before AppState has its
/// configuration and service, so the resolver reads both through
/// `AzureDevOpsPullRequestSource`, which AppState fills in once wired.
struct AzureDevOpsPullRequestResolver: PullRequestResolver {
    let source: AzureDevOpsPullRequestSource

    var id: String { "azure-devops" }

    func canResolve(_ url: URL) -> Bool {
        source.matcher?.link(for: url) != nil
    }

    func resolve(_ url: URL) async throws -> PullRequestDetails {
        guard let link = source.matcher?.link(for: url) else { throw PullRequestResolverError.noAnswer }
        let found = try await source.lookup(link)
        return PullRequestDetails(number: found.number,
                                  title: found.title.isEmpty ? nil : found.title,
                                  state: Self.state(found.state),
                                  repository: link.project + "/" + link.repository,
                                  headBranch: found.sourceBranch.isEmpty ? nil : found.sourceBranch)
    }

    static func state(_ state: FleetMateCore.PullRequestState) -> AgentsMate.PullRequestState {
        switch state {
        case .open: .open
        case .draft: .draft
        case .merged: .merged
        case .closed: .closed
        }
    }
}

/// What the resolver needs from the app: which links belong to the
/// configured organization, and a way to fetch one with the app's sign-in.
final class AzureDevOpsPullRequestSource: @unchecked Sendable {
    private let lock = NSLock()
    private var _matcher: AzureDevOpsPullRequestLink.Matcher?

    /// Nil until AppState sets it, and while no organization is configured.
    var matcher: AzureDevOpsPullRequestLink.Matcher? {
        get { lock.withLock { _matcher } }
        set { lock.withLock { _matcher = newValue } }
    }

    /// Fetches one pull request. Set by AppState; runs on the main actor,
    /// where the Azure DevOps service lives.
    @MainActor var fetch: ((AzureDevOpsPullRequestLink) async throws -> UnifiedPullRequest?)?

    @MainActor
    func lookup(_ link: AzureDevOpsPullRequestLink) async throws -> UnifiedPullRequest {
        guard let fetch else { throw PullRequestResolverError.unavailable }
        guard let found = try await fetch(link) else { throw PullRequestResolverError.noAnswer }
        return found
    }
}
