import SwiftUI
import FleetMateCore

/// The Manage tab's state: roster and sections, what is selected, what a
/// scan found, what the probe learned, and the operator's custom groups.
/// Owned by `AppState` so it survives tab switches (ContentView swaps tab
/// views wholesale) and is rebuilt when the config changes.
@MainActor
final class ManageState: ObservableObject {
    // MARK: - Configuration

    @Published private(set) var config: ManageConfig
    private var repoRoot: String?
    private var reportMate: ReportMateService?
    let store: ManageStateStore

    // MARK: - Roster

    @Published private(set) var roster: FleetRoster = .empty
    @Published private(set) var rosterError: String?
    @Published private(set) var isLoadingRoster = false
    @Published private(set) var rosterPath = ""

    // MARK: - Selection

    @Published var selection = ManageSelection()
    /// Serials of the checked machines in the current view.
    @Published var selectedComputerIDs: Set<String> = []
    @Published var customGroups: [CustomGroup] = []

    // MARK: - Scan

    @Published private(set) var scanResults: [String: HostScanResult] = [:]
    @Published private(set) var scanSummary = ScanSummary()
    @Published private(set) var isScanning = false
    @Published private(set) var scanStatus = ""
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var rescanningSerials: Set<String> = []
    private var scanTask: Task<Void, Never>?

    // MARK: - Probe

    @Published private(set) var machineInfos: [String: MachineInfo] = [:]
    @Published var sshUnavailable: Set<String> = []
    @Published private(set) var isFetchingInfo = false

    // MARK: - Command runner

    @Published var commandCategories: [CommandCategory] = []
    @Published var selectedCategoryID: UUID?
    @Published var selectedCommandID: UUID?
    @Published var customCommand = ""
    @Published var commandHistory: [CommandHistoryEntry] = []
    @Published var results: [String: CommandRunResult] = [:]
    @Published var isRunning = false
    @Published var runLabel = ""
    var runStartedAt: Date?
    var runTask: Task<Void, Never>?

    init(config: ManageConfig?, repoRoot: String?, reportMate: ReportMateService?, store: ManageStateStore = ManageStateStore()) {
        self.config = config ?? ManageConfig()
        self.repoRoot = repoRoot
        self.reportMate = reportMate
        self.store = store
        self.customGroups = store.loadCustomGroups()
        loadCommandLibrary()
    }

    /// Apply a saved config: reload the roster when its source changed.
    func reconfigure(config: ManageConfig?, repoRoot: String?, reportMate: ReportMateService?) {
        let previous = self.config
        let previousRoot = self.repoRoot
        self.config = config ?? ManageConfig()
        self.repoRoot = repoRoot
        self.reportMate = reportMate
        let rosterChanged = previous.resolvedRosterPath(repoRoot: previousRoot) != self.config.resolvedRosterPath(repoRoot: repoRoot)
            || previous.includeRetired != self.config.includeRetired
            || previous.includeProvisioning != self.config.includeProvisioning
        if rosterChanged || roster.isEmpty { loadRoster() }
        if previous.commandsPath != self.config.commandsPath { loadCommandLibrary() }
    }

    // MARK: - Roster loading

    func loadRoster() {
        isLoadingRoster = true
        rosterPath = config.resolvedRosterPath(repoRoot: repoRoot)
        defer { isLoadingRoster = false }
        guard !rosterPath.isEmpty else {
            roster = .empty
            rosterError = "No roster path is set. Choose computers.csv in Settings › Manage."
            return
        }
        do {
            roster = try RosterLoader(includeRetired: config.includeRetired, includeProvisioning: config.includeProvisioning)
                .load(path: rosterPath)
            rosterError = nil
            dbg.info("Roster loaded: \(roster.labs.count) labs, \(roster.kiosks.count) kiosk rooms, \(roster.staff.count) staff areas, \(roster.faculty.count) faculty buckets", category: "manage")
        } catch {
            roster = .empty
            rosterError = error.localizedDescription
            dbg.error("Roster load failed: \(error.localizedDescription)", category: "manage")
        }
        // Rooms may have changed identity; drop what no longer exists.
        selection.roomIDs = selection.roomIDs.filter { roster.room(id: $0) != nil }
        if selection.isEmpty { clearView() }
    }

    // MARK: - Derived

    var currentComputers: [RosterComputer] {
        selection.currentComputers(roster: roster, groups: customGroups)
    }

    var selectedComputers: [RosterComputer] {
        currentComputers.filter { selectedComputerIDs.contains($0.id) }
    }

    var onlineSelectedComputers: [RosterComputer] {
        selectedComputers.filter { isOnline($0) }
    }

    var currentLabel: String { selection.label(roster: roster, groups: customGroups) }

    var primaryRoom: RosterRoom? { selection.primaryRoom(in: roster) }
    var primaryGroup: CustomGroup? { selection.primaryGroup(in: customGroups) }

    var hasSelection: Bool { !selection.isEmpty }

    func scanResult(_ computer: RosterComputer) -> HostScanResult? { scanResults[computer.id] }

    func ipFor(_ computer: RosterComputer) -> String? {
        guard let r = scanResults[computer.id], r.hasAddress else { return nil }
        return r.ip
    }

    func isOnline(_ computer: RosterComputer) -> Bool {
        scanResults[computer.id]?.isOnline ?? false
    }

    var onlineCount: Int { currentComputers.filter { isOnline($0) }.count }

    // MARK: - Selection

    func selectRoom(_ room: RosterRoom, extending: Bool = false) {
        selection.selectRoom(room.id, extending: extending)
        viewChanged()
    }

    func selectRooms(_ ids: Set<String>) {
        selection.selectRooms(ids)
        viewChanged()
    }

    func selectGroup(_ group: CustomGroup, extending: Bool = false) {
        selection.selectGroup(group.id, extending: extending)
        viewChanged()
    }

    func selectSearchResults(_ computers: [RosterComputer], label: String) {
        selection.selectSearchResults(computers, label: label)
        viewChanged(selectAll: true)
    }

    func clearView() {
        scanTask?.cancel()
        scanTask = nil
        killCommand()
        selection.clear()
        selectedComputerIDs = []
        results = [:]
        scanResults = [:]
        scanSummary = ScanSummary()
        machineInfos = [:]
        sshUnavailable = []
        isScanning = false
        scanStatus = ""
        scanProgress = 0
    }

    func selectAll() { selectedComputerIDs = Set(currentComputers.map(\.id)) }
    func selectOnline() { selectedComputerIDs = Set(currentComputers.filter { isOnline($0) }.map(\.id)) }
    func selectNone() { selectedComputerIDs = [] }

    func toggleSelected(_ computer: RosterComputer) {
        if selectedComputerIDs.contains(computer.id) {
            selectedComputerIDs.remove(computer.id)
        } else {
            selectedComputerIDs.insert(computer.id)
        }
    }

    /// A machine added to the current view without joining a group.
    func addAdhocComputer(hostname: String, ip: String) {
        let computer = RosterComputer.adhoc(hostname: hostname, ip: ip)
        selection.addAdhoc(computer)
        if !ip.isEmpty {
            scanResults[computer.id] = HostScanResult(serial: computer.id, ip: ip, source: .stored)
            Task { await rescan(computer) }
        }
    }

    private func viewChanged(selectAll: Bool = false) {
        scanTask?.cancel()
        scanTask = nil
        killCommand()
        results = [:]
        isScanning = false
        scanStatus = ""
        scanResults = [:]
        scanSummary = ScanSummary()
        machineInfos = [:]
        sshUnavailable = []
        let computers = currentComputers
        selectedComputerIDs = selectAll ? Set(computers.map(\.id)) : []
        guard !computers.isEmpty else { scanProgress = 0; return }
        startScan()
    }

    // MARK: - Scanning

    func startScan() {
        let computers = currentComputers
        guard !computers.isEmpty, !isScanning else { return }
        let known = selection.knownAddresses(groups: customGroups)
        let scanner = makeScanner()
        isScanning = true
        scanProgress = 0
        scanStatus = "Checking ReportMate…"
        scanTask = Task { [weak self] in
            let (results, summary) = await scanner.scan(computers, knownAddresses: known) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.isScanning else { return }
                    self.scanStatus = progress.status
                    self.scanProgress = progress.fraction
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.scanResults = results
            self.scanSummary = summary
            self.isScanning = false
            self.scanStatus = ""
            self.scanProgress = 1
            self.rememberGroupAddresses(results)
            await self.fetchAllMachineInfo()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanStatus = ""
    }

    func rescan(_ computer: RosterComputer) async {
        guard !rescanningSerials.contains(computer.id) else { return }
        rescanningSerials.insert(computer.id)
        let known = scanResults[computer.id]?.ip ?? selection.knownAddresses(groups: customGroups)[computer.hostname]
        let result = await makeScanner().rescan(computer, knownIp: known)
        scanResults[computer.id] = result
        rescanningSerials.remove(computer.id)
        if result.isOnline {
            rememberGroupAddresses([computer.id: result])
            await fetchMachineInfo(for: [computer])
        } else {
            machineInfos.removeValue(forKey: computer.id)
        }
    }

    private func makeScanner() -> HostScanner {
        let directory: DeviceDirectory? = reportMate.map { ReportMateDeviceDirectory(service: $0) }
        return HostScanner(directory: directory, probe: NetworkReachabilityProbe(), concurrency: max(4, config.probeConcurrency))
    }

    /// Custom-group devices remember their last good address so the group
    /// opens online next time without resolving.
    private func rememberGroupAddresses(_ results: [String: HostScanResult]) {
        var changed = false
        for index in customGroups.indices where selection.groupIDs.contains(customGroups[index].id) {
            for deviceIndex in customGroups[index].devices.indices {
                let device = customGroups[index].devices[deviceIndex]
                let serial = RosterComputer.adhocSerialPrefix + device.hostname
                if let result = results[serial], result.hasAddress, result.ip != device.ip {
                    customGroups[index].devices[deviceIndex].ip = result.ip
                    changed = true
                }
            }
        }
        if changed { store.saveCustomGroups(customGroups) }
    }

    // MARK: - Machine info

    func makeExecutor() -> SecureShellService {
        SecureShellService(config: config.toSecureShellConfig(), reportMate: nil)
    }

    func fetchAllMachineInfo() async {
        await fetchMachineInfo(for: currentComputers.filter { isOnline($0) })
    }

    func fetchMachineInfo(for computers: [RosterComputer]) async {
        guard !isFetchingInfo else { return }
        let targets = computers.compactMap { c -> CommandRunner.Target? in
            guard let ip = ipFor(c) else { return nil }
            return CommandRunner.Target(computer: c, ip: ip)
        }
        guard !targets.isEmpty else { return }
        isFetchingInfo = true
        let service = MachineProbeService(executor: makeExecutor(), concurrency: max(1, config.probeConcurrency), username: config.resolvedSshUser)
        await service.probeAll(targets) { serial, outcome in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch outcome {
                case .info(let info):
                    self.machineInfos[serial] = info
                    self.sshUnavailable.remove(serial)
                case .authFailed:
                    self.sshUnavailable.insert(serial)
                case .unreachable, .failed:
                    // Reachability or a probe hiccup; not a key problem.
                    break
                }
            }
        }
        isFetchingInfo = false
    }

    // MARK: - Custom groups

    @discardableResult
    func createCustomGroup(name: String) -> UUID {
        let group = CustomGroup(name: name)
        customGroups.append(group)
        store.saveCustomGroups(customGroups)
        return group.id
    }

    func addDevice(toGroupID id: UUID, hostname: String, ip: String, serial: String? = nil) {
        guard let index = customGroups.firstIndex(where: { $0.id == id }) else { return }
        let device = AdhocDevice(hostname: hostname, ip: ip, serial: serial)
        guard !customGroups[index].devices.contains(where: { $0.hostname == device.hostname }) else { return }
        customGroups[index].devices.append(device)
        store.saveCustomGroups(customGroups)
        if selection.groupIDs.contains(id), !device.ip.isEmpty {
            let computer = device.computer
            scanResults[computer.id] = HostScanResult(serial: computer.id, ip: device.ip, source: .stored)
            Task { await rescan(computer) }
        }
    }

    func removeDevice(deviceID: UUID, fromGroupID groupID: UUID) {
        guard let index = customGroups.firstIndex(where: { $0.id == groupID }) else { return }
        customGroups[index].devices.removeAll { $0.id == deviceID }
        store.saveCustomGroups(customGroups)
    }

    func renameCustomGroup(id: UUID, newName: String) {
        guard let index = customGroups.firstIndex(where: { $0.id == id }) else { return }
        customGroups[index].name = newName
        store.saveCustomGroups(customGroups)
    }

    func deleteCustomGroup(id: UUID) {
        customGroups.removeAll { $0.id == id }
        store.saveCustomGroups(customGroups)
        if selection.groupIDs.contains(id) {
            selection.removeGroup(id)
            if selection.isEmpty { clearView() } else { viewChanged() }
        }
    }

    // MARK: - Remote access

    private var launcher: RemoteSessionLauncher { RemoteSessionLauncher(config: config) }

    private func session(for computer: RosterComputer) -> RemoteSessionLauncher.Session? {
        guard let ip = ipFor(computer) else { return nil }
        return RemoteSessionLauncher.Session(title: computer.displayName, address: ip)
    }

    /// SSH to one machine in a Terminal tab.
    func openSSH(for computer: RosterComputer) {
        guard let session = session(for: computer) else { return }
        launcher.openTerminal(sessions: [session])
    }

    /// One Terminal tab per online machine, in hostname order.
    func openSSHTabs(for computers: [RosterComputer]) {
        let sessions = computers
            .filter { isOnline($0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .compactMap(session(for:))
        launcher.openTerminal(sessions: sessions)
    }

    /// Screen Sharing to one machine, with the stored password when there is one.
    func openScreenSharing(for computer: RosterComputer) {
        guard let ip = ipFor(computer) else { return }
        launcher.openScreenSharing(address: ip, password: ScreenSharingCredentialStore.load())
    }

    func openSSHAndScreenSharing(for computer: RosterComputer) {
        openSSH(for: computer)
        openScreenSharing(for: computer)
    }

    // MARK: - Copy helpers

    /// One line for a ticket or hand-off note.
    func inventoryLine(for computer: RosterComputer) -> String {
        computer.inventoryLine(ip: ipFor(computer), osVersion: machineInfos[computer.id]?.osVersion)
    }
}
