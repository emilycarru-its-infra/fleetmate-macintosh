import SwiftUI
import FleetMateCore

/// The Autopilot side of the Devices list: a session cache of the tenant's
/// identities, and the actions on them.
///
/// Lives on AppState beside the Intune cache it is matched against, so
/// switching tabs keeps the read.
@MainActor
final class AutopilotStore: ObservableObject {
    @Published private(set) var identities: [WindowsAutopilotDevice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var lastLoaded: Date?

    /// The hashes of the import in flight or last finished, by import id.
    @Published private(set) var importProgress: [ImportedAutopilotIdentity] = []
    @Published private(set) var isImporting = false

    private var loadTask: Task<Void, Never>?

    /// Poll an import this often, and give up waiting after this long; Intune
    /// keeps processing, and a later refresh shows the result.
    static let importPollInterval: Duration = .seconds(15)
    static let importPollLimit: Duration = .seconds(15 * 60)

    /// Match the identities against the Intune records in front of the user.
    func index(intune: [IntuneDevice]) -> AutopilotIndex {
        AutopilotJoin.index(autopilot: identities, intune: intune)
    }

    func load(using graph: GraphService, force: Bool = false) {
        if !force, lastLoaded != nil || isLoading { return }
        loadTask?.cancel()
        loadTask = Task { await performLoad(graph) }
    }

    private func performLoad(_ graph: GraphService) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let all = try await graph.getAllAutopilotDevices()
            guard !Task.isCancelled else { return }
            identities = all
            lastLoaded = Date()
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            dbg.error("Autopilot read failed: \(error.localizedDescription)", category: "autopilot")
        }
    }

    // MARK: - Actions

    /// Run an action on identities, then re-read them. Returns a one-line
    /// outcome for the inspector.
    func perform(_ action: AutopilotAction, on targets: [WindowsAutopilotDevice], using graph: GraphService) async -> (ok: Bool, message: String) {
        let ids = targets.compactMap(\.id)
        guard !ids.isEmpty else { return (false, "No Autopilot identity selected.") }
        do {
            let results = try await graph.performAutopilotAction(action, autopilotIds: ids)
            let failed = results.filter { !$0.success }
            dbg.info("\(action.title) on \(ids.count) Autopilot identities: \(ids.count - failed.count) succeeded", category: "autopilot")
            if action == .delete {
                let gone = Set(results.filter(\.success).map(\.deviceId))
                identities.removeAll { $0.id.map(gone.contains) ?? false }
            } else {
                await reread(serials: targets.compactMap(\.serialNumber), using: graph)
            }
            let n = ids.count
            if failed.isEmpty {
                return (true, "\(action.title) completed for \(n) device\(n == 1 ? "" : "s").")
            }
            let reason = failed.compactMap(\.error).first ?? "unknown error"
            return (false, "\(action.title) failed for \(failed.count) of \(n): \(reason)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Re-read a few identities in place; a larger set re-reads the tenant.
    private func reread(serials: [String], using graph: GraphService) async {
        if serials.count > 25 {
            await performLoad(graph)
            return
        }
        var fresh: [String: WindowsAutopilotDevice] = [:]
        for serial in serials {
            if let identity = try? await graph.getAutopilotDeviceBySerial(serial), let id = identity.id {
                fresh[id] = identity
            }
        }
        identities = identities.map { identity in identity.id.flatMap { fresh[$0] } ?? identity }
    }

    func sync(using graph: GraphService) async -> (ok: Bool, message: String) {
        do {
            try await graph.syncAutopilot()
            return (true, "Autopilot sync requested. Intune allows one every ten minutes.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Hardware hash import

    /// Submit hashes, wait for Intune to process them, then sync and re-read.
    func importHashes(_ entries: [AutopilotHashEntry], using graph: GraphService) async -> (ok: Bool, message: String) {
        guard !entries.isEmpty else { return (false, "The file lists no devices.") }
        guard entries.count <= AutopilotHashCSV.maxEntries else {
            return (false, "Intune imports at most \(AutopilotHashCSV.maxEntries) devices at once; split the file.")
        }
        isImporting = true
        defer { isImporting = false }
        do {
            importProgress = try await graph.importAutopilotHashes(entries)
            dbg.info("Submitted \(entries.count) hardware hashes for Autopilot import", category: "autopilot")

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Self.importPollLimit)
            while importProgress.contains(where: { !$0.isFinished }), clock.now < deadline {
                try await Task.sleep(for: Self.importPollInterval)
                let pending = importProgress.filter { !$0.isFinished }.map(\.id)
                let fresh = Dictionary(uniqueKeysWithValues: try await graph.getImportedAutopilotIdentities(ids: pending).map { ($0.id, $0) })
                importProgress = importProgress.map { fresh[$0.id] ?? $0 }
            }

            let done = importProgress.filter(\.succeeded).count
            let failed = importProgress.filter { $0.failureReason != nil }
            let waiting = importProgress.count - done - failed.count
            if done > 0 {
                _ = await sync(using: graph)
                await performLoad(graph)
            }
            var parts = ["Imported \(done) of \(importProgress.count)."]
            if !failed.isEmpty {
                parts.append("\(failed.count) failed: " + failed.prefix(3).map { "\($0.serialNumber ?? $0.id) (\($0.failureReason ?? "error"))" }.joined(separator: ", ") + ".")
            }
            if waiting > 0 { parts.append("\(waiting) still processing; refresh later.") }
            return (failed.isEmpty && waiting == 0, parts.joined(separator: " "))
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
