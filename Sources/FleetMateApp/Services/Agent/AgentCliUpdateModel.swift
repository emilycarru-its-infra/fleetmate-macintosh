import Foundation
import FleetMateCore

/// Keeps `codex` and `claude` current in the background: a check at launch,
/// another whenever six hours have passed, and one before an agent session
/// starts if the last is that old. Updates run with the tool that installed
/// each CLI, never interactively, so a session opens straight to the agent
/// instead of on its updater. Results go to the app log and to a neutral
/// status line in Settings › Agent.
@MainActor
final class AgentCliUpdateModel: ObservableObject {
    @Published private(set) var state: AgentCliUpdateState
    @Published private(set) var isRunning = false

    private let updater = AgentCliUpdater()
    private var loop: Task<Void, Never>?

    init() {
        state = AgentCliUpdateState.load()
    }

    /// The Settings toggle, on unless turned off.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AgentSettingsKey.keepClisCurrent) as? Bool ?? true
    }

    /// Begin the launch check and the six-hourly schedule.
    func start() {
        guard loop == nil, !AppEdition.current.isTicketsOnly else { return }
        loop = Task { [weak self] in
            // Let launch settle before spawning Homebrew or npm.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                self?.updateIfStale()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    /// Update in the background if enabled and the last check is old enough.
    func updateIfStale() {
        guard isEnabled, !isRunning, state.isStale() else { return }
        Task { await run(checkOnly: false) }
    }

    /// Check (and, unless `checkOnly`, update) now.
    func run(checkOnly: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let previous = state
        let updater = updater
        let next = await Task.detached(priority: .utility) {
            await updater.run(checkOnly: checkOnly, previous: previous)
        }.value
        next.save()
        state = next
    }
}
