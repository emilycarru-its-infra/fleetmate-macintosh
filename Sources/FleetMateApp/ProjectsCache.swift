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

    // Reference data backing the create/edit menus
    var teamMembers: [IdentityRef] = []
    var areaPaths: [String] = []
    var iterationPaths: [String] = []
    var workItemTypes: [WorkItemTypeDefinition] = []
    var repositories: [GitRepository] = []
    var statesPerType: [String: [String]] = [:]

    var syncEnabled = false

    /// When the task list last loaded. Nil means never — the only case that
    /// should show a full-page spinner.
    var loadedAt: Date?
}
