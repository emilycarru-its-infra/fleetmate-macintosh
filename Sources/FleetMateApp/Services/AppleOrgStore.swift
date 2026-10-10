import SwiftUI
import FleetMateCore

/// Every configured Apple School / Business Manager organization, read
/// together and merged into the Devices list. Each device carries the
/// organization that holds it, and every action goes to that organization.
///
/// Lives on AppState so switching tabs keeps the snapshot — reading an
/// organization costs a minute of Apple's per-organization quota.
@MainActor
final class AppleOrgStore: ObservableObject {
    @Published private(set) var profiles: [AppleOrgProfile] = []
    @Published private(set) var devices: [AppleOrgDevice] = []
    @Published private(set) var servers: [AppleOrgServer] = []
    @Published private(set) var isLoading = false
    /// Read failures by profile name. One organization failing never hides
    /// the devices another one holds.
    @Published private(set) var loadErrors: [String: String] = [:]
    @Published private(set) var lastLoaded: Date?

    /// AppleCare per serial, read when a device is selected and kept for the
    /// session. A missing entry is a read in flight.
    @Published private(set) var appleCare: [String: Result<[AppleCareAgreement], Error>] = [:]

    /// Activation Lock per serial, read when a device is selected and kept for
    /// the session. A missing entry is a read not yet made or still in flight.
    @Published private(set) var activationLock: [String: AppleActivationLock] = [:]

    private var services: [String: AppleOrgService] = [:]
    private var loadTask: Task<Void, Never>?
    /// The Key Vault sources from settings, one per organization.
    private(set) var sources: [AppleOrgSource] = []
    /// A view asked for the organizations before their profiles were read;
    /// read them as soon as the profiles arrive.
    private var loadWanted = false

    init() {}

    /// Take the sources from settings, and re-read the profiles when they change.
    func configure(sources: [AppleOrgSource]) {
        guard sources != self.sources else { return }
        self.sources = sources
        Task { await reloadProfiles() }
    }

    var hasProfile: Bool { !profiles.isEmpty }

    /// Display names by profile name: the service, plus the profile name only
    /// when two organizations are the same kind.
    var orgLabels: [String: String] { AppleOrgProfile.labels(for: profiles) }

    func profile(named name: String) -> AppleOrgProfile? { profiles.first { $0.name == name } }

    func label(for orgId: String) -> String { orgLabels[orgId] ?? "Apple Organization" }

    func servers(in orgId: String) -> [AppleOrgServer] { servers.filter { $0.orgId == orgId } }

    /// Re-read the profile list from Key Vault, and the organizations if it changed.
    func reloadProfiles() async {
        let fresh = await AppleOrgService.profiles(for: sources)
        guard fresh != profiles else { return }
        let hadLoaded = lastLoaded != nil
        profiles = fresh
        resetSession()
        if hadLoaded || loadWanted { load(force: true) }
    }

    private func resetSession() {
        loadTask?.cancel()
        services = [:]
        devices = []
        servers = []
        appleCare = [:]
        activationLock = [:]
        lastLoaded = nil
        loadErrors = [:]
    }

    private func service(for orgId: String) async throws -> AppleOrgService {
        if let s = services[orgId] { return s }
        guard profile(named: orgId) != nil, let source = sources.first(where: { $0.name == orgId }) else {
            throw AppleOrgError.noProfile
        }
        let s = try await AppleOrgService.connect(source: source)
        services[orgId] = s
        return s
    }

    // MARK: - Loading

    /// Read every organization unless this session already has them.
    func load(force: Bool = false) {
        loadWanted = true
        guard hasProfile else {
            dbg.debug("No Apple organization profiles found", category: "appleorg")
            return
        }
        if !force, lastLoaded != nil || isLoading { return }
        // Mark the read as started before the task runs, so a second call in
        // the same update (a view's .task can fire twice) does not cancel it.
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { await performLoad() }
    }

    /// Organizations are read at the same time: Apple's quota is per
    /// organization, so the wait is the slowest one rather than the sum.
    private func performLoad() async {
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        let names = profiles.map(\.name)
        var connected: [String: AppleOrgService] = [:]
        var errors: [String: String] = [:]
        for name in names {
            do { connected[name] = try await service(for: name) }
            catch {
                errors[name] = error.localizedDescription
                dbg.error("Apple organization sign-in failed: \(error.localizedDescription)", category: "appleorg")
            }
        }

        // Start every organization's read before awaiting any of them.
        let reads = connected.map { name, service in
            (name, Task { try await service.snapshot() })
        }
        var results: [(String, Result<(devices: [AppleOrgDevice], servers: [AppleOrgServer]), Error>)] = []
        for (name, read) in reads {
            do { results.append((name, .success(try await read.value))) }
            catch { results.append((name, .failure(error))) }
        }
        guard !Task.isCancelled else {
            dbg.debug("Apple organization read superseded by a newer one", category: "appleorg")
            return
        }

        var allDevices: [AppleOrgDevice] = []
        var allServers: [AppleOrgServer] = []
        for (name, result) in results {
            switch result {
            case .success(let snapshot):
                allDevices += snapshot.devices
                allServers += snapshot.servers
            case .failure(let error):
                errors[name] = error.localizedDescription
                dbg.error("Apple organization read failed for a profile: \(error.localizedDescription)", category: "appleorg")
            }
        }
        devices = allDevices
        servers = allServers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loadErrors = errors
        lastLoaded = Date()
        dbg.debug("Apple organizations merged: \(devices.count) devices from \(results.count) of \(names.count) profiles", category: "appleorg")
    }

    func loadAppleCare(for device: AppleOrgDevice) {
        let serial = device.serialNumber
        guard appleCare[serial] == nil else { return }
        Task {
            do {
                let s = try await service(for: device.orgId)
                appleCare[serial] = .success(try await s.appleCare(serial: serial))
            } catch {
                appleCare[serial] = .failure(error)
            }
        }
    }

    func loadActivationLock(for device: AppleOrgDevice) {
        let serial = device.serialNumber
        guard activationLock[serial] == nil else { return }
        Task {
            do {
                let s = try await service(for: device.orgId)
                activationLock[serial] = try await s.activationLock(serial: serial)
            } catch {
                // A failed read is unknown, never disabled.
                activationLock[serial] = .unknown
                dbg.warn("Activation Lock read failed: \(error.localizedDescription)", category: "appleorg")
            }
        }
    }

    // MARK: - Actions

    /// Run an action in one organization, wait for Apple to finish it, then
    /// re-read what changed. Returns a one-line outcome for the actions panel.
    func perform(_ action: AppleOrgAction, serials: [String], in orgId: String) async -> (ok: Bool, message: String) {
        let activity = ActivityLog.shared.begin(action.title, service: "Apple", serials: serials)
        let outcome = await performUnlogged(action, serials: serials, in: orgId)
        ActivityLog.shared.finish(activity, failure: outcome.ok ? nil : outcome.message)
        return outcome
    }

    private func performUnlogged(_ action: AppleOrgAction, serials: [String], in orgId: String) async -> (ok: Bool, message: String) {
        do {
            let s = try await service(for: orgId)
            let result = try await s.perform(action, serials: serials)
            await reread(serials, in: s, dropMissing: action == .release)
            let n = serials.count
            if result.succeeded {
                return (true, "\(action.title) completed for \(n) device\(n == 1 ? "" : "s").")
            }
            if result.status == "TIMEOUT" {
                return (false, "Apple is still processing \(action.title.lowercased()) for \(n) device\(n == 1 ? "" : "s"); refresh later.")
            }
            return (false, "\(action.title) ended \(result.status.lowercased()). Some devices may not have changed.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func reread(_ serials: [String], in service: AppleOrgService, dropMissing: Bool) async {
        if serials.count > AppleOrgService.perDeviceRereadLimit {
            await performLoad()
            return
        }
        let orgId = service.profile.name
        let fresh = await service.reread(serials: serials)
        let bySerial = Dictionary(fresh.map { ($0.serialNumber, $0) }, uniquingKeysWith: { a, _ in a })
        // After a release, a device that no longer reads back has left the
        // organization. After anything else a missing read is a failed read,
        // so the row keeps its last known state.
        let released = dropMissing ? Set(serials).subtracting(bySerial.keys) : []
        let oldServers = Dictionary(devices.filter { $0.orgId == orgId }.map { ($0.serialNumber, $0.assignedServerId) },
                                    uniquingKeysWith: { a, _ in a })
        devices = devices.compactMap { d in
            guard d.orgId == orgId else { return d }
            if released.contains(d.serialNumber) { return nil }
            return bySerial[d.serialNumber] ?? d
        }
        // Keep the service counts honest without another full listing.
        for serial in serials {
            let before = oldServers[serial] ?? nil
            let after = bySerial[serial]?.assignedServerId
            guard before != after else { continue }
            adjustCount(before, by: -1)
            adjustCount(after, by: 1)
        }
    }

    private func adjustCount(_ serverId: String?, by delta: Int) {
        guard let serverId, let i = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[i].deviceCount = max(0, (servers[i].deviceCount ?? 0) + delta)
    }
}
