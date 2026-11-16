import Foundation
import FleetMateCore

/// The icon and colour chosen for each repository, shared by the Repos
/// sidebar and the agent terminal so a choice made in either shows in both.
@MainActor
final class RepoIcons: ObservableObject {
    static let shared = RepoIcons()

    @Published private(set) var choices: [String: RepoIconChoice]
    private let store: RepoIconStore

    init(store: RepoIconStore = RepoIconStore()) {
        self.store = store
        choices = store.load()
    }

    func choice(for repoId: String) -> RepoIconChoice? { choices[repoId] }

    /// Saves a choice, or returns the repository to the default look when
    /// `choice` is nil. Does nothing when nothing changes.
    func set(_ choice: RepoIconChoice?, for repoId: String) {
        guard choices[repoId] != choice else { return }
        var updated = choices
        if let choice { updated[repoId] = choice } else { updated.removeValue(forKey: repoId) }
        choices = updated
        try? store.save(updated)
    }
}
