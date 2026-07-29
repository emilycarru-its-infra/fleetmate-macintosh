import Foundation
import Alamofire

public enum GraphServiceError: Error, CustomStringConvertible {
    case notAuthenticated
    case notFound(String)

    public var description: String {
        switch self {
        case .notAuthenticated: return "Not authenticated to Microsoft Graph"
        case .notFound(let what): return "Not found: \(what)"
        }
    }
}

/// Microsoft Graph service for Intune devices and Entra ID users/groups
/// Uses Azure CLI SSO for authentication on macOS
public class GraphService {
    private let config: FleetMateConfig
    private let session: Session
    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    // Caches
    private var userCache: [String: (user: EntraUser, expiry: Date)] = [:]
    private var groupCache: [String: (group: EntraGroup, expiry: Date)] = [:]
    private let cacheDuration: TimeInterval

    private let baseUrl = "https://graph.microsoft.com/v1.0"
    private let graphResourceId = "https://graph.microsoft.com"

    // Transport: by default every Graph call runs inside an `aze` session (the
    // domain identity's token never leaves Azure). Set the environment variable
    // FLEETMATE_GRAPH_TRANSPORT=direct to fall back to a local Alamofire request
    // with an `az`-minted delegated token (dev / break-glass).
    private let useAze: Bool
    private let azeTransport: AzeGraphTransport
    private static let graphDecoder = JSONDecoder()

    public var isConfigured: Bool {
        return config.isGraphConfigured
    }

    public init(config: FleetMateConfig) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = Session(configuration: configuration)

        self.useAze = config.graphUsesAze
        self.azeTransport = AzeGraphTransport()
    }

    // MARK: - Session warming

    /// Pre-warm the elevation sessions Graph uses (Intune → devices, Entra →
    /// identity) so the container cold start is paid at launch, not on the
    /// first user action. No-op in direct mode. Best-effort and concurrent.
    @discardableResult
    public func warmElevationSessions() async -> Bool {
        guard useAze else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            for domain in [GraphDomain.devices, GraphDomain.identity] {
                group.addTask { await self.azeTransport.warm(domain) }
            }
            var allWarmed = true
            for await warmed in group { allWarmed = allWarmed && warmed }
            return allWarmed
        }
    }

    // MARK: - Authentication

    private func getAccessToken() async throws -> String? {
        if let token = cachedToken, Date() < tokenExpiry {
            return token
        }

        // Use Azure CLI SSO
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/az")
        process.arguments = ["account", "get-access-token", "--resource", graphResourceId, "--query", "accessToken", "-o", "tsv"]

        // Try Homebrew arm64 path if standard path doesn't exist
        if !FileManager.default.fileExists(atPath: "/usr/local/bin/az") {
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/az") {
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/az")
            } else {
                print("Azure CLI not found. Please install it: brew install azure-cli")
                return nil
            }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                print("Azure CLI failed to get token. Run 'az login' first.")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            cachedToken = token
            tokenExpiry = Date().addingTimeInterval(55 * 60) // 55 minutes

            return token
        } catch {
            print("Failed to run Azure CLI: \(error)")
            return nil
        }
    }

    private func headers() async -> HTTPHeaders? {
        // In aze mode auth happens inside the session — return a non-nil empty
        // header set so existing `guard let headers` call sites pass through.
        if useAze { return [:] }
        guard let token = try? await getAccessToken() else { return nil }
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }

    /// Graph's hard ceiling for `$top` on directory collections.
    ///
    /// Asking for more is not merely capped — the request fails outright with
    /// `Request_UnsupportedQuery` ("Invalid page size specified"), so a caller
    /// wanting 1000 groups gets zero of them.
    private static let maxGraphPageSize = 999

    /// Page size for a request that wants `limit` results in total.
    ///
    /// This is a *page* size, not a cap on the result: every paged call here
    /// follows `@odata.nextLink` until it reaches `limit`.
    private func pageSize(for limit: Int) -> Int {
        min(limit, config.graphPageSize, Self.maxGraphPageSize)
    }

    // MARK: - Intune Devices

    public func getManagedDevices(filter: String? = nil, limit: Int = 100) async throws -> [IntuneDevice] {
        guard let headers = await headers() else { return [] }

        var url = "\(baseUrl)/deviceManagement/managedDevices?$top=\(pageSize(for: limit))"
        if let filter = filter {
            url += "&$filter=\(filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter)"
        }

        var allDevices: [IntuneDevice] = []

        while let currentUrl = URL(string: url), allDevices.count < limit {
            let response: IntuneDeviceListResponse = try await fetch(url: currentUrl.absoluteString, headers: headers)
            allDevices.append(contentsOf: response.value)

            if let nextLink = response.nextLink {
                url = nextLink
            } else {
                break
            }
        }

        return Array(allDevices.prefix(limit))
    }

    public func getDeviceBySerial(_ serialNumber: String) async throws -> IntuneDevice? {
        let filter = "serialNumber eq '\(serialNumber)'"
        let devices = try await getManagedDevices(filter: filter, limit: 1)
        return devices.first
    }

    public func getDeviceByName(_ deviceName: String) async throws -> IntuneDevice? {
        let filter = "deviceName eq '\(deviceName)'"
        let devices = try await getManagedDevices(filter: filter, limit: 1)
        return devices.first
    }

    public func searchDevices(_ query: String, limit: Int = 50) async throws -> [IntuneDevice] {
        let filter = "startswith(deviceName, '\(query)')"
        return try await getManagedDevices(filter: filter, limit: limit)
    }

    public func getDeviceCompliance(deviceId: String) async throws -> [DeviceCompliancePolicyState] {
        guard let headers = await headers() else { return [] }

        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/deviceCompliancePolicyStates"
        let response: CompliancePolicyStatesResponse = try await fetch(url: url, headers: headers)
        return response.value
    }

    public func getNonCompliantDevices(limit: Int = 100) async throws -> [IntuneDevice] {
        let filter = "complianceState eq 'noncompliant'"
        return try await getManagedDevices(filter: filter, limit: limit)
    }

    // MARK: - Device Details

    public func getDeviceGroupMemberships(_ azureADDeviceId: String) async throws -> [DeviceGroupMembership] {
        guard let headers = await headers() else { return [] }

        let url = "\(baseUrl)/devices/\(azureADDeviceId)/memberOf"
        let response: DeviceMemberOfResponse = try await fetch(url: url, headers: headers)
        return response.value
    }

    public func getDetectedApps(_ managedDeviceId: String) async throws -> [DetectedApp] {
        guard let headers = await headers() else { return [] }

        let url = "\(baseUrl)/deviceManagement/managedDevices/\(managedDeviceId)/detectedApps"
        let response: DetectedAppsResponse = try await fetch(url: url, headers: headers)
        return response.value
    }

    // MARK: - Mobile Apps

    public func getMobileApps(limit: Int = 100) async throws -> [MobileApp] {
        guard let headers = await headers() else { return [] }

        var url = "\(baseUrl)/deviceAppManagement/mobileApps?$top=\(pageSize(for: limit))"
        var allApps: [MobileApp] = []

        while let currentUrl = URL(string: url), allApps.count < limit {
            let response: MobileAppsResponse = try await fetch(url: currentUrl.absoluteString, headers: headers)
            allApps.append(contentsOf: response.value)

            if let nextLink = response.nextLink {
                url = nextLink
            } else {
                break
            }
        }

        return Array(allApps.prefix(limit))
    }

    public func searchMobileApps(_ query: String, limit: Int = 50) async throws -> [MobileApp] {
        guard let headers = await headers() else { return [] }

        let filter = "contains(displayName, '\(query)')"
        let escapedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        let url = "\(baseUrl)/deviceAppManagement/mobileApps?$filter=\(escapedFilter)&$top=\(limit)"

        let response: MobileAppsResponse = try await fetch(url: url, headers: headers)
        return response.value
    }

    // MARK: - Device Actions

    public func syncDevices(_ deviceIds: [String]) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/managedDevices/\(deviceId)/syncDevice"
                    do {
                        try await self.postAction(url: url, headers: headers)
                        return BulkActionResult(deviceId: deviceId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: deviceId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    public func rebootDevices(_ deviceIds: [String]) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/managedDevices/\(deviceId)/rebootNow"
                    do {
                        try await self.postAction(url: url, headers: headers)
                        return BulkActionResult(deviceId: deviceId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: deviceId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    public func remoteLockDevices(_ deviceIds: [String], pin: String? = nil) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/managedDevices/\(deviceId)/remoteLock"
                    do {
                        if let pin = pin {
                            try await self.postAction(url: url, body: ["pin": pin], headers: headers)
                        } else {
                            try await self.postAction(url: url, headers: headers)
                        }
                        return BulkActionResult(deviceId: deviceId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: deviceId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Factory-reset devices. `keepEnrollmentData`/`keepUserData` map to the
    /// Intune wipe action options (default full wipe).
    public func wipeDevices(_ deviceIds: [String], keepEnrollmentData: Bool = false, keepUserData: Bool = false) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/managedDevices/\(deviceId)/wipe"
                    do {
                        try await self.postAction(url: url, body: ["keepEnrollmentData": keepEnrollmentData, "keepUserData": keepUserData], headers: headers)
                        return BulkActionResult(deviceId: deviceId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: deviceId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Retire devices — removes company data and unenrolls, leaving personal
    /// data intact (POST .../retire).
    public func retireDevices(_ deviceIds: [String]) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/managedDevices/\(deviceId)/retire"
                    do {
                        try await self.postAction(url: url, headers: headers)
                        return BulkActionResult(deviceId: deviceId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: deviceId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    // MARK: - Proactive Remediations

    private struct DeviceHealthScriptRef: Decodable { let id: String }

    private static func utcParts() -> (date: String, time: String, stamp: String) {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: Date())
        f.dateFormat = "HH:mm:ss"
        let time = f.string(from: Date())
        return (date, time, "\(date) \(time)")
    }

    /// Create a proactive remediation (deviceHealthScript) and assign it to a
    /// group with a run-once schedule. Returns the new script id.
    @discardableResult
    public func deployRemediation(displayName: String, detectionScript: String, remediationScript: String, group groupNameOrId: String, description: String? = nil) async throws -> String {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        guard let groupId = try await resolveGroupId(groupNameOrId) else {
            throw GraphServiceError.notFound("group \(groupNameOrId)")
        }

        let createBody: [String: Any] = [
            "displayName": displayName,
            "description": description ?? "Deployed by FleetMate",
            "publisher": "FleetMate",
            "runAsAccount": "system",
            "enforceSignatureCheck": false,
            "runAs32Bit": false,
            "detectionScriptContent": Data(detectionScript.utf8).base64EncodedString(),
            "remediationScriptContent": Data(remediationScript.utf8).base64EncodedString(),
        ]
        let created: DeviceHealthScriptRef = try await post(url: "\(baseUrl)/deviceManagement/deviceHealthScripts", body: createBody, headers: headers)

        let now = GraphService.utcParts()
        let assignBody: [String: Any] = [
            "deviceHealthScriptAssignments": [[
                "target": [
                    "@odata.type": "#microsoft.graph.groupAssignmentTarget",
                    "groupId": groupId,
                ],
                "runRemediationScript": true,
                "runSchedule": [
                    "@odata.type": "#microsoft.graph.deviceHealthScriptRunOnceSchedule",
                    "date": now.date,
                    "time": now.time,
                    "useUtc": true,
                ],
            ]],
        ]
        try await postAction(url: "\(baseUrl)/deviceManagement/deviceHealthScripts/\(created.id)/assign", body: assignBody, headers: headers)
        return created.id
    }

    /// Deploy the Cimian push trigger remediation to a group — a proactive
    /// remediation that writes `.cimian.headless` on target Windows devices to
    /// force an immediate managed software update run.
    @discardableResult
    public func deployCimianPushRemediation(group groupNameOrId: String) async throws -> String {
        let stamp = GraphService.utcParts().stamp
        let detectionScript = """
        # Cimian Push - Detection Script
        # Exit 0 = remediation needed (trigger file does not exist)
        # Exit 1 = no action needed (trigger file already exists or MSU is running)

        $triggerFile = 'C:\\ProgramData\\ManagedInstalls\\.cimian.headless'
        $msuProcess = Get-Process -Name 'managedsoftwareupdate' -ErrorAction SilentlyContinue

        if ($msuProcess) {
            Write-Output 'managedsoftwareupdate is already running'
            exit 1
        }

        if (Test-Path $triggerFile) {
            $age = (Get-Date) - (Get-Item $triggerFile).LastWriteTime
            if ($age.TotalMinutes -lt 5) {
                Write-Output 'Trigger file exists and is recent'
                exit 1
            }
        }

        Write-Output 'Cimian push trigger needed'
        exit 0
        """
        let remediationScript = """
        # Cimian Push - Remediation Script
        # Creates .cimian.headless trigger file for CimianWatcher to pick up

        $managedInstallsDir = 'C:\\ProgramData\\ManagedInstalls'
        $triggerFile = Join-Path $managedInstallsDir '.cimian.headless'

        if (-not (Test-Path $managedInstallsDir)) {
            New-Item -ItemType Directory -Path $managedInstallsDir -Force | Out-Null
        }

        $content = @"
        Bootstrap triggered at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode: Headless
        Triggered by: FleetMate Intune Push
        "@

        Set-Content -Path $triggerFile -Value $content -Force
        Write-Output "Cimian push trigger created at $triggerFile"

        $svc = Get-Service -Name 'CimianWatcher' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Start-Service -Name 'CimianWatcher' -ErrorAction SilentlyContinue
            Write-Output 'CimianWatcher service was stopped, started it'
        }
        """
        return try await deployRemediation(
            displayName: "Cimian Push Trigger - \(stamp)",
            detectionScript: detectionScript,
            remediationScript: remediationScript,
            group: groupNameOrId,
            description: "FleetMate-initiated Cimian push trigger. Creates .cimian.headless to force an immediate managed software update run.")
    }

    // MARK: - Entra Users

    public func getUser(_ userPrincipalNameOrId: String, includeGroups: Bool = false) async throws -> EntraUser? {
        let cacheKey = userPrincipalNameOrId.lowercased()
        if let cached = userCache[cacheKey], Date() < cached.expiry {
            return cached.user
        }

        guard let headers = await headers() else { return nil }

        let escapedId = userPrincipalNameOrId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userPrincipalNameOrId
        // Graph returns almost none of the inspector fields (incl. accountEnabled)
        // by default, so request them explicitly.
        let url = "\(baseUrl)/users/\(escapedId)?$select=\(EntraUser.inspectorSelect)"

        var user: EntraUser = try await fetch(url: url, headers: headers)

        if includeGroups {
            user.memberOf = try await getUserGroups(userPrincipalNameOrId)
        }

        userCache[cacheKey] = (user, Date().addingTimeInterval(cacheDuration))
        return user
    }

    /// The user's manager (nil when none / not permitted). The manager endpoint
    /// 404s when a user has no manager, which surfaces as a thrown error here.
    public func getUserManager(_ userPrincipalNameOrId: String) async throws -> EntraUserRef? {
        guard let headers = await headers() else { return nil }
        let escapedId = userPrincipalNameOrId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userPrincipalNameOrId
        let url = "\(baseUrl)/users/\(escapedId)/manager?$select=id,displayName,userPrincipalName,jobTitle"
        return try? await fetch(url: url, headers: headers) as EntraUserRef
    }

    /// Devices the user has registered / signed in to (Entra device objects).
    public func getUserDevices(_ userPrincipalNameOrId: String) async throws -> [EntraDevice] {
        guard let headers = await headers() else { return [] }
        let escapedId = userPrincipalNameOrId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userPrincipalNameOrId
        var url = "\(baseUrl)/users/\(escapedId)/registeredDevices"
        var devices: [EntraDevice] = []
        while URL(string: url) != nil {
            let response: EntraDeviceListResponse = try await fetch(url: url, headers: headers)
            devices.append(contentsOf: response.value)
            if let nextLink = response.nextLink { url = nextLink } else { break }
        }
        return devices
    }

    public func getUserGroups(_ userPrincipalNameOrId: String) async throws -> [EntraGroup] {
        guard let headers = await headers() else { return [] }

        let escapedId = userPrincipalNameOrId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userPrincipalNameOrId
        var url = "\(baseUrl)/users/\(escapedId)/memberOf"
        var groups: [EntraGroup] = []

        while let _ = URL(string: url) {
            let response: UserMemberOfResponse = try await fetch(url: url, headers: headers)

            for obj in response.value where obj.isGroup {
                groups.append(EntraGroup(
                    id: obj.id,
                    displayName: obj.displayName,
                    description: obj.description,
                    mail: nil,
                    mailEnabled: nil,
                    securityEnabled: nil,
                    groupTypes: nil
                ))
            }

            if let nextLink = response.nextLink {
                url = nextLink
            } else {
                break
            }
        }

        return groups
    }

    public func searchUsers(_ query: String, limit: Int = 25) async throws -> [EntraUser] {
        guard let headers = await headers() else { return [] }

        let filter = "startswith(displayName, '\(query)') or startswith(userPrincipalName, '\(query)') or startswith(mail, '\(query)')"
        let escapedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        // Explicit $select so the row's enabled/disabled state is correct.
        let url = "\(baseUrl)/users?$filter=\(escapedFilter)&$top=\(limit)&$select=\(EntraUser.rowSelect)"

        let response: EntraUserListResponse = try await fetch(url: url, headers: headers)
        return response.value
    }

    public func checkGroupMembership(user userPrincipalNameOrId: String, group groupNameOrId: String) async throws -> Bool {
        guard let headers = await headers() else { return false }

        // Get group ID if name was provided
        var groupId = groupNameOrId
        if UUID(uuidString: groupNameOrId) == nil {
            guard let group = try await getGroupByName(groupNameOrId) else { return false }
            groupId = group.id ?? ""
        }

        // Get user
        guard let user = try await getUser(userPrincipalNameOrId) else { return false }

        let url = "\(baseUrl)/users/\(user.id ?? "")/checkMemberGroups"
        let body: [String: Any] = ["groupIds": [groupId]]

        let response: CheckMemberGroupsResponse = try await post(url: url, body: body, headers: headers)
        return response.value.contains(groupId)
    }

    // MARK: - Entra Groups

    public func getGroupByName(_ displayName: String) async throws -> EntraGroup? {
        let cacheKey = displayName.lowercased()
        if let cached = groupCache[cacheKey], Date() < cached.expiry {
            return cached.group
        }

        guard let headers = await headers() else { return nil }

        let filter = "displayName eq '\(displayName)'"
        let escapedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        let url = "\(baseUrl)/groups?$filter=\(escapedFilter)"

        let response: EntraGroupListResponse = try await fetch(url: url, headers: headers)
        if let group = response.value.first {
            groupCache[cacheKey] = (group, Date().addingTimeInterval(cacheDuration))
            return group
        }
        return nil
    }

    public func getGroupById(_ groupId: String) async throws -> EntraGroup? {
        guard let headers = await headers() else { return nil }

        let url = "\(baseUrl)/groups/\(groupId)"
        return try await fetch(url: url, headers: headers)
    }

    public func getGroupMembers(_ groupNameOrId: String, limit: Int = 100) async throws -> [EntraUser] {
        guard let headers = await headers() else { return [] }

        // Get group ID if name was provided
        var groupId = groupNameOrId
        if UUID(uuidString: groupNameOrId) == nil {
            guard let group = try await getGroupByName(groupNameOrId) else { return [] }
            groupId = group.id ?? ""
        }

        var url = "\(baseUrl)/groups/\(groupId)/members?$top=\(pageSize(for: limit))"
        var members: [EntraUser] = []

        while let _ = URL(string: url), members.count < limit {
            let response: GroupMembersResponse = try await fetch(url: url, headers: headers)
            members.append(contentsOf: response.value)

            if let nextLink = response.nextLink {
                url = nextLink
            } else {
                break
            }
        }

        return Array(members.prefix(limit))
    }

    public func getGroupDeviceMembers(_ groupId: String, limit: Int = 100) async throws -> [EntraDevice] {
        guard let headers = await headers() else { return [] }

        var url = "\(baseUrl)/groups/\(groupId)/members/microsoft.graph.device?$top=\(pageSize(for: limit))"
        var devices: [EntraDevice] = []

        while let _ = URL(string: url), devices.count < limit {
            let response: EntraDeviceListResponse = try await fetch(url: url, headers: headers)
            devices.append(contentsOf: response.value)

            if let nextLink = response.nextLink {
                url = nextLink
            } else {
                break
            }
        }

        return Array(devices.prefix(limit))
    }

    public func searchGroups(_ query: String, limit: Int = 999) async throws -> [EntraGroup] {
        guard let headers = await headers() else { return [] }

        let filter = "startswith(displayName, '\(query)')"
        let escapedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        var url = "\(baseUrl)/groups?$filter=\(escapedFilter)&$top=\(pageSize(for: limit))"

        // Paginate: a prefix like "Devices-" matches far more than one page, and
        // the caller filters the full set client-side (so e.g. "Shared-" can match
        // "Devices-Shared-*").
        var groups: [EntraGroup] = []
        while URL(string: url) != nil, groups.count < limit {
            let response: EntraGroupListResponse = try await fetch(url: url, headers: headers)
            groups.append(contentsOf: response.value)
            if let nextLink = response.nextLink { url = nextLink } else { break }
        }
        return Array(groups.prefix(limit))
    }

    // MARK: - Entra Writes (group membership, user state)

    /// Resolve a group name or id to its object id (passes ids through).
    private func resolveGroupId(_ groupNameOrId: String) async throws -> String? {
        if UUID(uuidString: groupNameOrId) != nil { return groupNameOrId }
        return try await getGroupByName(groupNameOrId)?.id
    }

    /// Resolve a user UPN or id to its object id (passes ids through).
    private func resolveUserId(_ userPrincipalNameOrId: String) async throws -> String? {
        if UUID(uuidString: userPrincipalNameOrId) != nil { return userPrincipalNameOrId }
        return try await getUser(userPrincipalNameOrId)?.id
    }

    /// Add a directory object (user or device) to a group.
    public func addGroupMember(group groupNameOrId: String, objectId: String) async throws {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        guard let groupId = try await resolveGroupId(groupNameOrId) else {
            throw GraphServiceError.notFound("group \(groupNameOrId)")
        }
        let url = "\(baseUrl)/groups/\(groupId)/members/$ref"
        let body: [String: Any] = ["@odata.id": "\(baseUrl)/directoryObjects/\(objectId)"]
        try await postAction(url: url, body: body, headers: headers)
    }

    /// Remove a directory object from a group.
    public func removeGroupMember(group groupNameOrId: String, objectId: String) async throws {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        guard let groupId = try await resolveGroupId(groupNameOrId) else {
            throw GraphServiceError.notFound("group \(groupNameOrId)")
        }
        let url = "\(baseUrl)/groups/\(groupId)/members/\(objectId)/$ref"
        try await deleteAction(url: url, headers: headers)
    }

    /// Enable or disable a user account (PATCH accountEnabled).
    public func setUserAccountEnabled(_ userPrincipalNameOrId: String, enabled: Bool) async throws {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        guard let userId = try await resolveUserId(userPrincipalNameOrId) else {
            throw GraphServiceError.notFound("user \(userPrincipalNameOrId)")
        }
        let url = "\(baseUrl)/users/\(userId)"
        try await patchAction(url: url, body: ["accountEnabled": enabled], headers: headers)
    }

    // MARK: - Private Helpers

    private func fetch<T: Decodable>(url: String, headers: HTTPHeaders) async throws -> T {
        if useAze {
            let data = try await azeTransport.send(GraphRequest(method: .get, url: url))
            return try GraphService.graphDecoder.decode(T.self, from: data)
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: T.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    private func postAction(url: String, body: [String: Any]? = nil, headers: HTTPHeaders) async throws {
        if useAze {
            let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            _ = try await azeTransport.send(GraphRequest(method: .post, url: url, body: bodyData))
            return
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request: DataRequest
            if let body = body {
                request = session.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
            } else {
                request = session.request(url, method: .post, headers: headers)
            }
            request.validate().response { response in
                switch response.result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func patchAction(url: String, body: [String: Any], headers: HTTPHeaders) async throws {
        if useAze {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            _ = try await azeTransport.send(GraphRequest(method: .patch, url: url, body: bodyData))
            return
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .patch, parameters: body, encoding: JSONEncoding.default, headers: headers)
                .validate()
                .response { response in
                    switch response.result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    private func deleteAction(url: String, headers: HTTPHeaders) async throws {
        if useAze {
            _ = try await azeTransport.send(GraphRequest(method: .delete, url: url))
            return
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .delete, headers: headers)
                .validate()
                .response { response in
                    switch response.result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    private func post<T: Decodable>(url: String, body: [String: Any], headers: HTTPHeaders) async throws -> T {
        if useAze {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let data = try await azeTransport.send(GraphRequest(method: .post, url: url, body: bodyData))
            return try GraphService.graphDecoder.decode(T.self, from: data)
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseDecodable(of: T.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
}
