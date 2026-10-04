import SwiftUI
import FleetMateCore

/// The Apple organization behind the Devices tab's Mac view: the active
/// profile, a session cache of the organization, and the actions on it.
///
/// Lives on AppState so switching tabs keeps the snapshot — reading an
/// organization costs a minute of Apple's per-organization quota.
@MainActor
final class AppleOrgStore: ObservableObject {
    enum Connection: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    @Published private(set) var profiles: [AppleOrgProfile] = []
    @Published private(set) var activeProfileName: String = ""
    @Published private(set) var connection: Connection = .disconnected

    @Published private(set) var devices: [AppleOrgDevice] = []
    @Published private(set) var servers: [AppleOrgServer] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var lastLoaded: Date?

    /// AppleCare per serial, read when a device is selected and kept for the
    /// session. A nil entry is a read in flight.
    @Published private(set) var appleCare: [String: Result<[AppleCareAgreement], Error>] = [:]

    private var service: AppleOrgService?
    private var loadTask: Task<Void, Never>?

    init() { reloadProfiles() }

    var hasProfile: Bool { !profiles.isEmpty }
    var activeProfile: AppleOrgProfile? { profiles.first { $0.name == activeProfileName } }
    var isSchool: Bool { activeProfile?.isSchool ?? false }

    func reloadProfiles() {
        profiles = AppleOrgService.profiles()
        let current = AppleOrgService.currentProfileName
        let resolved = profiles.contains { $0.name == current } ? current : (profiles.first?.name ?? "")
        if resolved != activeProfileName, !activeProfileName.isEmpty {
            // The active profile was removed: drop what was read with it.
            resetSession()
        }
        activeProfileName = resolved
    }

    private func resetSession() {
        loadTask?.cancel()
        service = nil
        connection = .disconnected
        devices = []
        servers = []
        appleCare = [:]
        lastLoaded = nil
        loadError = nil
    }

    func switchProfile(_ name: String) {
        guard name != activeProfileName else { return }
        loadTask?.cancel()
        AppleOrgService.setCurrentProfile(name)
        resetSession()
        activeProfileName = name
        load(force: true)
    }

    private func connected() async throws -> AppleOrgService {
        if let service { return service }
        guard !activeProfileName.isEmpty else { throw AppleOrgError.noProfile }
        connection = .connecting
        do {
            let s = try await AppleOrgService.connect(profileName: activeProfileName)
            service = s
            connection = .connected
            return s
        } catch {
            connection = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Loading

    /// Read the organization unless this session already has it.
    func load(force: Bool = false) {
        if !force, lastLoaded != nil || isLoading { return }
        loadTask?.cancel()
        loadTask = Task { await performLoad() }
    }

    private func performLoad() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let s = try await connected()
            let snapshot = try await s.snapshot()
            guard !Task.isCancelled else { return }
            devices = snapshot.devices
            servers = snapshot.servers
            lastLoaded = Date()
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            dbg.error("Apple organization read failed: \(error.localizedDescription)", category: "appleorg")
        }
    }

    func loadAppleCare(serial: String) {
        guard appleCare[serial] == nil else { return }
        Task {
            do {
                let s = try await connected()
                let agreements = try await s.appleCare(serial: serial)
                appleCare[serial] = .success(agreements)
            } catch {
                appleCare[serial] = .failure(error)
            }
        }
    }

    // MARK: - Actions

    /// Run an action, wait for Apple to finish it, then re-read what changed.
    /// Returns a one-line outcome for the actions panel.
    func perform(_ action: AppleOrgAction, serials: [String]) async -> (ok: Bool, message: String) {
        do {
            let s = try await connected()
            let result = try await s.perform(action, serials: serials)
            await reread(serials, dropMissing: action == .release)
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

    private func reread(_ serials: [String], dropMissing: Bool) async {
        guard let service else { return }
        if serials.count > AppleOrgService.perDeviceRereadLimit {
            await performLoad()
            return
        }
        let fresh = await service.reread(serials: serials)
        let bySerial = Dictionary(fresh.map { ($0.serialNumber, $0) }, uniquingKeysWith: { a, _ in a })
        // After a release, a device that no longer reads back has left the
        // organization. After anything else a missing read is a failed read,
        // so the row keeps its last known state.
        let released = dropMissing ? Set(serials).subtracting(bySerial.keys) : []
        let oldServers = Dictionary(devices.map { ($0.serialNumber, $0.assignedServerId) }, uniquingKeysWith: { a, _ in a })
        devices = devices.compactMap { d in
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
