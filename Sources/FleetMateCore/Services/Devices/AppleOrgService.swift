import Foundation
import ASBMUtilCore

/// Apple School Manager / Apple Business Manager, through asbmutil's client.
///
/// Credentials are asbmutil's own keychain profiles, so a profile made with
/// `asbmutil config set` works here unchanged and one added in FleetMate's
/// Settings works in the CLI. Everything Apple-specific stays behind this
/// type: the app layer sees only FleetMate's `AppleOrg*` models.
public actor AppleOrgService {
    public nonisolated let profile: AppleOrgProfile
    private let client: APIClient

    /// Above this many serials, a re-read after an action reloads the whole
    /// organization instead: Apple allows an organization about twenty
    /// requests a minute, and a full read costs one per thousand devices plus
    /// one per service.
    public static let perDeviceRereadLimit = 15

    private init(profile: AppleOrgProfile, client: APIClient) {
        self.profile = profile
        self.client = client
    }

    /// Sign in with a stored profile. The token is cached in the keychain by
    /// asbmutil, so this is a request only when the cached one has expired.
    public static func connect(profileName: String) async throws -> AppleOrgService {
        let credentials = try Creds.load(profileName: profileName)
        let client = try await APIClient(credentials: credentials, profileName: profileName)
        let profile = AppleOrgProfile(name: profileName, clientId: credentials.clientId)
        dbg.info("Connected to \(profile.serviceName) profile '\(profileName)'", category: "appleorg")
        return AppleOrgService(profile: profile, client: client)
    }

    // MARK: - Profiles

    public static func profiles() -> [AppleOrgProfile] {
        var found = ASBMUtilCore.Keychain.listProfiles()
            .map { AppleOrgProfile(name: $0.name, clientId: $0.clientId) }
        // asbmutil's profile list can be empty while credentials exist — the
        // list and the credentials are stored separately, and an older
        // `config set` wrote only the latter. The current and default
        // profiles are always worth probing directly.
        for name in [currentProfileName, "default"] where !found.contains(where: { $0.name == name }) {
            if let blob = ASBMUtilCore.Keychain.loadBlob(profileName: name), !blob.clientId.isEmpty {
                found.append(AppleOrgProfile(name: name, clientId: blob.clientId))
            }
        }
        // Two profiles holding the same credential are one organization;
        // reading both would count every device twice. A named profile is
        // kept over the generic "default".
        var byClient: [String: AppleOrgProfile] = [:]
        for p in found {
            if let kept = byClient[p.clientId], kept.name != "default" { continue }
            byClient[p.clientId] = p
        }
        return byClient.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static var currentProfileName: String { ASBMUtilCore.Keychain.getCurrentProfile() }

    public static func setCurrentProfile(_ name: String) {
        ASBMUtilCore.Keychain.setCurrentProfile(name)
    }

    /// Store a profile from a client ID, key ID and the private key file Apple
    /// issued. The PEM text goes into the keychain; the file is not kept.
    public static func saveProfile(name: String, clientId: String, keyId: String, privateKeyFile: URL) throws {
        let pem = try String(contentsOf: privateKeyFile, encoding: .utf8)
        guard pem.contains("PRIVATE KEY") else {
            throw AppleOrgError.invalidPrivateKey
        }
        let blob = KCBlob(
            clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            keyId: keyId.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKey: pem,
            teamId: ""
        )
        let status = ASBMUtilCore.Keychain.saveBlob(blob, profileName: name)
        guard status == errSecSuccess else { throw AppleOrgError.keychain(status) }
        if profiles().count == 1 { setCurrentProfile(name) }
    }

    public static func deleteProfile(_ name: String) {
        _ = ASBMUtilCore.Keychain.deleteBlob(profileName: name)
    }

    // MARK: - Reading

    /// The whole organization: every device, every service, and which service
    /// each device is assigned to. Costs one request per thousand devices plus
    /// one per service, whatever the fleet size.
    public func snapshot() async throws -> (devices: [AppleOrgDevice], servers: [AppleOrgServer]) {
        async let deviceList = client.listDevices(devicesPerPage: 1000)
        async let serverList = client.listMdmServers()
        let (attributes, rawServers) = try await (deviceList, serverList)

        let client = self.client
        let listings = try await withThrowingTaskGroup(of: (String, [String]).self) { group in
            for server in rawServers {
                group.addTask { (server.id, try await client.listMdmServerDevices(serverId: server.id)) }
            }
            var out: [String: [String]] = [:]
            for try await (id, serials) in group { out[id] = serials }
            return out
        }
        let assignments = AppleOrgJoin.assignments(fromServerListings: listings)

        let servers = rawServers.map {
            AppleOrgServer(id: $0.id, orgId: profile.name, name: $0.serverName ?? $0.id, type: $0.serverType,
                           deviceCount: listings[$0.id]?.count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let devices = attributes.map { attr in
            self.map(attr, assignedServerId: assignments[AppleOrgJoin.normalize(attr.serialNumber)]
                     ?? attr.deviceManagementServiceId)
        }
        dbg.info("Read \(devices.count) devices and \(servers.count) services from \(profile.serviceName)", category: "appleorg")
        return (devices, servers)
    }

    /// Re-read a few devices after an action, one request pair per device.
    public func reread(serials: [String]) async -> [AppleOrgDevice] {
        let client = self.client
        let orgId = profile.name
        return await withTaskGroup(of: AppleOrgDevice?.self) { group in
            // Apple drops HTTP/2 streams above about four at once.
            var pending = serials[...]
            func addNext() {
                guard let serial = pending.popFirst() else { return }
                group.addTask {
                    guard let attr = try? await client.getDeviceAttributes(serialNumber: serial) else { return nil }
                    let server = try? await client.getAssignedMdmRaw(deviceId: serial).data?.id
                    return Self.map(attr, orgId: orgId, assignedServerId: server)
                }
            }
            for _ in 0..<4 { addNext() }
            var out: [AppleOrgDevice] = []
            for await device in group {
                if let device { out.append(device) }
                addNext()
            }
            return out
        }
    }

    /// AppleCare and warranty coverage. Apple serves it one device at a time.
    public func appleCare(serial: String) async throws -> [AppleCareAgreement] {
        let coverage = try await client.getAppleCareCoverage(deviceSerialNumber: serial)
        return coverage.coverages.map {
            AppleCareAgreement(
                description: $0.description ?? "Coverage",
                status: $0.status,
                start: $0.startDateTime.flatMap(APIClient.parseISO8601),
                end: $0.endDateTime.flatMap(APIClient.parseISO8601),
                agreementNumber: $0.agreementNumber,
                paymentType: $0.paymentType,
                isCanceled: $0.isCanceled ?? false
            )
        }
    }

    // MARK: - Actions

    /// Submit an activity and wait for Apple to finish it.
    public func perform(_ action: AppleOrgAction, serials: [String]) async throws -> AppleOrgActivityResult {
        guard !serials.isEmpty else { throw AppleOrgError.noDevices }
        if action.isBusinessOnly && profile.isSchool { throw AppleOrgError.businessOnly }

        dbg.info("\(action.title): \(serials.count) device(s) via \(profile.serviceName)", category: "appleorg")
        let details: ActivityDetails
        switch action {
        case .assign(let serverId):
            details = try await client.createDeviceActivity(type: .assignDevices, serials: serials, serviceId: serverId)
        case .unassign(let serverId):
            details = try await client.createDeviceActivity(type: .unassignDevices, serials: serials, serviceId: serverId)
        case .scheduleMigration(let serverId, let deadline):
            details = try await client.scheduleMdmMigration(serials: serials, serviceId: serverId, deadline: Self.iso(deadline))
        case .updateMigrationDeadline(let deadline):
            details = try await client.updateMdmMigrationDeadline(serials: serials, deadline: Self.iso(deadline))
        case .cancelMigration:
            details = try await client.cancelMdmMigration(serials: serials)
        case .release:
            details = try await client.releaseDevices(serials: serials)
        }

        let status: String
        if APIClient.isTerminalActivityStatus(details.status) {
            status = details.status
        } else {
            status = try await client.waitForActivityTerminal(id: details.id, intervalSeconds: 3, timeoutSeconds: 180)
        }
        dbg.info("\(action.title) activity \(details.id) ended \(status)", category: "appleorg")
        return AppleOrgActivityResult(activityId: details.id, status: status, serials: serials)
    }

    // MARK: - Mapping

    func map(_ a: DeviceAttributes, assignedServerId: String?) -> AppleOrgDevice {
        Self.map(a, orgId: profile.name, assignedServerId: assignedServerId)
    }

    static func map(_ a: DeviceAttributes, orgId: String, assignedServerId: String?) -> AppleOrgDevice {
        AppleOrgDevice(
            serialNumber: a.serialNumber,
            orgId: orgId,
            model: a.displayModel,
            productFamily: a.productFamily,
            status: a.status,
            assignedServerId: assignedServerId,
            orderNumber: a.orderNumber,
            purchaseSource: a.purchaseSourceType,
            addedToOrg: a.addedToOrgDateTime.flatMap(APIClient.parseISO8601),
            orderDate: a.orderDateTime.flatMap(APIClient.parseISO8601),
            isMigrationCapable: a.isMdmMigrationCapable,
            migrationStatus: a.mdmMigrationStatus,
            migrationDeadline: a.mdmMigrationDeadlineDateTime.flatMap(APIClient.parseISO8601),
            releasedFromOrg: a.releasedFromOrgDateTime.flatMap(APIClient.parseISO8601),
            wifiMacAddresses: a.wifiMacAddress?.allValues ?? [],
            ethernetMacAddresses: a.builtInEthernetMacAddress?.allValues ?? []
        )
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

public enum AppleOrgError: LocalizedError {
    case noProfile
    case noDevices
    case businessOnly
    case invalidPrivateKey
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noProfile: "No Apple School or Business Manager profile is configured."
        case .noDevices: "No devices were selected."
        case .businessOnly: "Releasing devices is available only in Apple Business Manager."
        case .invalidPrivateKey: "That file is not a PEM private key."
        case .keychain(let status): "The keychain refused the profile (status \(status))."
        }
    }
}
