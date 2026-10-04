import Foundation
import FleetMateCore

/// The Projects tab's loaded data, held on AppState so it survives tab switches.
///
/// A struct rather than an ObservableObject: mutating any field republishes the
/// AppState that owns it, whereas a nested class would need its own observation
/// wired up at every use site.
struct ProjectsCache {
    // Work items and issues
    var allTasks: [UnifiedTask] = []
    var buckets: [String] = []

    // Boards
    var availableBoards: [Board] = []
    var selectedBoardName: String?
    var boardColumnDefs: [BoardColumnDefinition] = []
    var boardAllowedTypes: Set<String> = []
    var boardProjectMap: [String: String] = [:]
    var boardTeamMap: [String: String] = [:]

    // GitHub project context
    var currentProjectId: String?
    var currentGhConfig: GitHubProviderConfig?
    var projectStatusField: GitHubProjectField?

    // GitHub Projects v2 board (the Projects mode). Loaded on first open and on
    // Refresh only — never polled, since every page is a GraphQL query against
    // the shared per-user budget.
    var githubBoardItems: [GitHubProjectItem] = []
    var githubBoardLoadedAt: Date?
    var githubBoardError: String?
    /// Refresh requests made, and the one the loaded items answer. They differ
    /// only after Refresh, which is what makes the board reload.
    var githubBoardRefreshRequested = 0
    var githubBoardRefreshLoaded = 0

    // Reference data backing the create/edit menus
    var teamMembers: [IdentityRef] = []
    var areaPaths: [String] = []
    var iterationPaths: [String] = []
    var workItemTypes: [WorkItemTypeDefinition] = []
    var repositories: [GitRepository] = []
    var statesPerType: [String: [String]] = [:]

    var syncEnabled = false

    // Stored queries (Azure DevOps Shared Queries) backing the List view
    var sharedQueries: [AdoSharedQuery] = []
    var queryRuns: [String: QueryRunDisplay] = [:]
    var collapsedQueryIds: Set<String> = []

    /// When the task list last loaded. Nil means never — the only case that
    /// should show a full-page spinner.
    var loadedAt: Date?

    /// When the stored queries last loaded, same nil-means-never contract.
    var queriesLoadedAt: Date?

    /// Why the last shared-queries load produced nothing. An empty list and a
    /// refused request look identical on screen otherwise, and the refusal is
    /// the one the user can act on.
    var queriesLoadError: String?
}
