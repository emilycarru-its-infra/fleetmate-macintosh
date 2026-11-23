import Foundation
import FleetMateCore

/// Keeps the Agent folders (Settings › Repositories › Agent Folders) and the tracked
/// repositories (Settings › Repositories) in step, both ways: each folder the
/// Agent lists is linked and tracked, and each tracked checkout joins the
/// Agent's list. Nothing is removed from either side.
@MainActor
enum AgentRepoSync {
    /// Set once the Agent has synced on its first opening.
    static let didFirstSyncKey = "agentTerminal.reposSyncedOnce"

    struct Result {
        var repos: [String]
        var addedToAgent: Int
        var trackedNow: Int
        var failures: [String]

        var summary: String {
            var parts: [String] = []
            parts.append(addedToAgent == 1 ? "1 repository added to the Agent" : "\(addedToAgent) repositories added to the Agent")
            parts.append(trackedNow == 1 ? "1 now tracked" : "\(trackedNow) now tracked")
            if !failures.isEmpty { parts.append("\(failures.count) could not be linked") }
            return parts.joined(separator: ", ") + "."
        }
    }

    static func sync(_ agent: [String]) async -> Result {
        let manager = RepoManager()
        var failures: [String] = []
        var trackedNow = 0
        let records = (try? manager.records()) ?? []
        let byPath = Dictionary(records.compactMap { record in
            record.local.map { (AgentRepoList.normalized($0.path), record) }
        }, uniquingKeysWith: { first, _ in first })

        for path in AgentRepoList.localPaths(agent) where FileManager.default.fileExists(atPath: path) {
            if let record = byPath[path] {
                guard !record.isTracked else { continue }
                do { _ = try manager.setTracked(record.id, true); trackedNow += 1 }
                catch { failures.append("\(path): \(error.localizedDescription)") }
            } else {
                do { _ = try await manager.link(path: path, tracked: true); trackedNow += 1 }
                catch { failures.append("\(path): \(error.localizedDescription)") }
            }
        }

        let tracked = ((try? manager.records()) ?? [])
            .filter { $0.isTracked && !$0.isHidden }
            .compactMap { $0.local?.path }
            .filter { FileManager.default.fileExists(atPath: AgentRepoList.normalized($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let merged = AgentRepoList.merged(agent: agent, tracked: tracked)
        UserDefaults.standard.set(merged, forKey: AgentSettingsKey.repos)
        if trackedNow > 0 { NotificationCenter.default.post(name: .repoRegistryChanged, object: nil) }
        return Result(repos: merged, addedToAgent: merged.count - agent.count, trackedNow: trackedNow, failures: failures)
    }

    /// The first time the Agent opens, sync once without asking.
    static func syncOnFirstOpen(_ appState: AppState) {
        guard !UserDefaults.standard.bool(forKey: didFirstSyncKey) else { return }
        UserDefaults.standard.set(true, forKey: didFirstSyncKey)
        let current = appState.agentRepos
        Task {
            _ = await sync(current)
            appState.objectWillChange.send()
        }
    }
}
