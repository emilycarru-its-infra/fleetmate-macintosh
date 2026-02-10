import Foundation
import Alamofire

/// Service principal type for Graph API authentication
public enum GraphServicePrincipal {
    case devices   // Intune - uses devicesGraphId/devicesGraphSecret
    case systems   // Entra users/groups - uses systemsGraphId/systemsGraphSecret
    case azureCli  // Fallback - uses Azure CLI SSO (for DevOps/Planner)
}

/// Microsoft Graph service for Intune devices and Entra ID users/groups
/// Uses separate service principals for different API scopes:
/// - Devices (Intune): uses devicesGraphId/devicesGraphSecret
/// - Systems (Entra): uses systemsGraphId/systemsGraphSecret
/// - DevOps/Planner: uses Azure CLI SSO
public class GraphService {
    private let config: FleetMateConfig
    private let session: Session
    
    // Token caches for each service principal
    private var devicesToken: String?
    private var devicesTokenExpiry: Date = .distantPast
    private var systemsToken: String?
    private var systemsTokenExpiry: Date = .distantPast
    private var cliToken: String?
    private var cliTokenExpiry: Date = .distantPast

    // Entity caches
    private var userCache: [String: (user: EntraUser, expiry: Date)] = [:]
    private var groupCache: [String: (group: EntraGroup, expiry: Date)] = [:]
    private let cacheDuration: TimeInterval

    private let baseUrl = "https://graph.microsoft.com/v1.0"
    private let graphResourceId = "https://graph.microsoft.com"

    public var isConfigured: Bool {
        return config.isGraphConfigured
    }

    public init(config: FleetMateConfig) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = Session(configuration: configuration)
    }

    // MARK: - Authentication

    /// Get access token for the specified service principal
    private func getAccessToken(for principal: GraphServicePrincipal) async throws -> String? {
        switch principal {
        case .devices:
            if let token = devicesToken, Date() < devicesTokenExpiry {
                return token
            }
            // Try dedicated devices SP first, fall back to shared credentials
            let devClientId = config.devicesGraphId ?? config.graphClientId
            let devClientSecret = config.devicesGraphSecret ?? config.graphClientSecret
            guard let clientId = devClientId,
                  let clientSecret = devClientSecret,
                  let tenantId = config.graphTenantId else {
                print("[GraphService] Devices service principal not configured")
                return nil
            }
            let token = try await getClientCredentialsToken(tenantId: tenantId, clientId: clientId, clientSecret: clientSecret)
            devicesToken = token
            devicesTokenExpiry = Date().addingTimeInterval(55 * 60)
            return token
            
        case .systems:
            if let token = systemsToken, Date() < systemsTokenExpiry {
                return token
            }
            // Try dedicated systems SP first, fall back to shared credentials
            let sysClientId = config.systemsGraphId ?? config.graphClientId
            let sysClientSecret = config.systemsGraphSecret ?? config.graphClientSecret
            guard let clientId = sysClientId,
                  let clientSecret = sysClientSecret,
                  let tenantId = config.graphTenantId else {
                print("[GraphService] Systems service principal not configured")
                return nil
            }
            let token = try await getClientCredentialsToken(tenantId: tenantId, clientId: clientId, clientSecret: clientSecret)
            systemsToken = token
            systemsTokenExpiry = Date().addingTimeInterval(55 * 60)
            return token
            
        case .azureCli:
            if let token = cliToken, Date() < cliTokenExpiry {
                return token
            }
            let token = try await getAzureCliToken()
            cliToken = token
            cliTokenExpiry = Date().addingTimeInterval(55 * 60)
            return token
        }
    }
    
    /// Get token using client credentials flow (OAuth2)
    private func getClientCredentialsToken(tenantId: String, clientId: String, clientSecret: String) async throws -> String? {
        let tokenUrl = "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/token"
        
        let parameters: [String: String] = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "scope": "https://graph.microsoft.com/.default",
            "grant_type": "client_credentials"
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(tokenUrl, method: .post, parameters: parameters, encoding: URLEncoding.default)
                .responseDecodable(of: TokenResponse.self) { response in
                    switch response.result {
                    case .success(let tokenResponse):
                        continuation.resume(returning: tokenResponse.accessToken)
                    case .failure(let error):
                        print("[GraphService] Token request failed: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
        }
    }
    
    /// Token response from OAuth2 token endpoint
    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String
        let expiresIn: Int
        
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    /// Get token using Azure CLI (for user-context operations)
    private func getAzureCliToken() async throws -> String? {
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
            return token
        } catch {
            print("Failed to run Azure CLI: \(error)")
            return nil
        }
    }

    /// Get headers for the specified service principal
    private func headers(for principal: GraphServicePrincipal) async -> HTTPHeaders? {
        guard let token = try? await getAccessToken(for: principal) else { return nil }
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }
    
    /// Legacy headers using Azure CLI (deprecated)
    private func headers() async -> HTTPHeaders? {
        return await headers(for: .azureCli)
    }

    // MARK: - Intune Devices (uses devices service principal)

    public func getManagedDevices(filter: String? = nil, limit: Int = 100) async throws -> [IntuneDevice] {
        guard let headers = await headers(for: .devices) else { return [] }

        var url = "\(baseUrl)/deviceManagement/managedDevices?$top=\(min(limit, config.graphPageSize))"
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
        guard let headers = await headers(for: .devices) else { return [] }

        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/deviceCompliancePolicyStates"
        let response: CompliancePolicyStatesResponse = try await fetch(url: url, headers: headers)
        return response.value
    }

    public func getNonCompliantDevices(limit: Int = 100) async throws -> [IntuneDevice] {
        let filter = "complianceState eq 'noncompliant'"
        return try await getManagedDevices(filter: filter, limit: limit)
    }
    
    // MARK: - Intune Device Actions
    
    /// Result of a device action
    public struct DeviceActionResult {
        public let success: Bool
        public let deviceId: String
        public let action: String
        public let message: String?
    }
    
    /// Force sync a managed device
    public func syncDevice(_ deviceId: String) async throws -> DeviceActionResult {
        guard let headers = await headers(for: .devices) else {
            return DeviceActionResult(success: false, deviceId: deviceId, action: "syncDevice", message: "Not authenticated")
        }
        
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/syncDevice"
        return try await postAction(url: url, headers: headers, deviceId: deviceId, action: "syncDevice")
    }
    
    /// Sync multiple devices in parallel
    public func syncDevices(_ deviceIds: [String]) async throws -> [DeviceActionResult] {
        return await withTaskGroup(of: DeviceActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    do {
                        return try await self.syncDevice(deviceId)
                    } catch {
                        return DeviceActionResult(success: false, deviceId: deviceId, action: "syncDevice", message: error.localizedDescription)
                    }
                }
            }
            
            var results: [DeviceActionResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    /// Reboot a managed device
    public func rebootDevice(_ deviceId: String) async throws -> DeviceActionResult {
        guard let headers = await headers(for: .devices) else {
            return DeviceActionResult(success: false, deviceId: deviceId, action: "rebootNow", message: "Not authenticated")
        }
        
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/rebootNow"
        return try await postAction(url: url, headers: headers, deviceId: deviceId, action: "rebootNow")
    }
    
    /// Reboot multiple devices
    public func rebootDevices(_ deviceIds: [String]) async throws -> [DeviceActionResult] {
        return await withTaskGroup(of: DeviceActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    do {
                        return try await self.rebootDevice(deviceId)
                    } catch {
                        return DeviceActionResult(success: false, deviceId: deviceId, action: "rebootNow", message: error.localizedDescription)
                    }
                }
            }
            
            var results: [DeviceActionResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    /// Remote lock a device with optional PIN (macOS/iOS)
    public func remoteLockDevice(_ deviceId: String, pin: String? = nil) async throws -> DeviceActionResult {
        guard let headers = await headers(for: .devices) else {
            return DeviceActionResult(success: false, deviceId: deviceId, action: "remoteLock", message: "Not authenticated")
        }
        
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/remoteLock"
        
        if let pin = pin, !pin.isEmpty {
            let body: [String: Any] = ["pin": pin]
            return try await postAction(url: url, body: body, headers: headers, deviceId: deviceId, action: "remoteLock")
        } else {
            return try await postAction(url: url, headers: headers, deviceId: deviceId, action: "remoteLock")
        }
    }
    
    /// Remote lock multiple devices
    public func remoteLockDevices(_ deviceIds: [String], pin: String? = nil) async throws -> [DeviceActionResult] {
        return await withTaskGroup(of: DeviceActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    do {
                        return try await self.remoteLockDevice(deviceId, pin: pin)
                    } catch {
                        return DeviceActionResult(success: false, deviceId: deviceId, action: "remoteLock", message: error.localizedDescription)
                    }
                }
            }
            
            var results: [DeviceActionResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    /// Schedule Windows Update installation
    public func windowsUpdateAction(_ deviceId: String, scheduledDateTime: Date? = nil) async throws -> DeviceActionResult {
        guard let headers = await headers(for: .devices) else {
            return DeviceActionResult(success: false, deviceId: deviceId, action: "windowsDefenderScan", message: "Not authenticated")
        }
        
        // For Windows updates, we use the initiateOnDemandProactiveRemediation or trigger update scan
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/windowsDefenderUpdateSignatures"
        return try await postAction(url: url, headers: headers, deviceId: deviceId, action: "windowsDefenderUpdateSignatures")
    }
    
    /// Trigger app reinstall by triggering device sync and app reassignment check
    public func reinstallApp(_ deviceId: String, appId: String) async throws -> DeviceActionResult {
        // Note: Graph API doesn't have a direct "reinstall app" endpoint
        // The closest is to sync the device which triggers policy and app re-evaluation
        // For LOB apps, we can use reprovision
        return try await syncDevice(deviceId)
    }
    
    /// Get detected apps on a device
    public func getDetectedApps(_ deviceId: String) async throws -> [DetectedApp] {
        guard let headers = await headers(for: .devices) else { return [] }
        
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/detectedApps"
        let response: DetectedAppsResponse = try await fetch(url: url, headers: headers)
        return response.value
    }
    
    /// Get apps assigned to a device
    public func getDeviceAppInstallStates(_ deviceId: String, userId: String? = nil) async throws -> [MobileAppInstallStatus] {
        guard let headers = await headers(for: .devices) else { return [] }
        
        // Try to get user-specific install states if userId is provided
        if let userId = userId {
            let url = "\(baseUrl)/users/\(userId)/mobileAppInstallStatuses"
            let response: MobileAppInstallStatusResponse = try await fetch(url: url, headers: headers)
            return response.value.filter { $0.deviceId == deviceId }
        }
        
        return []
    }
    
    /// Get mobile apps from Intune
    public func getMobileApps(filter: String? = nil, limit: Int = 100) async throws -> [MobileApp] {
        guard let headers = await headers(for: .devices) else { return [] }
        
        var url = "\(baseUrl)/deviceAppManagement/mobileApps?$top=\(min(limit, config.graphPageSize))"
        if let filter = filter {
            url += "&$filter=\(filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter)"
        }
        
        var allApps: [MobileApp] = []
        
        while let _ = URL(string: url), allApps.count < limit {
            let response: MobileAppsResponse = try await fetch(url: url, headers: headers)
            allApps.append(contentsOf: response.value)
            
            if let nextLink = response.nextLink {
                url = nextLink
            } else {
                break
            }
        }
        
        return Array(allApps.prefix(limit))
    }
    
    /// Search mobile apps by name
    public func searchMobileApps(_ query: String, limit: Int = 50) async throws -> [MobileApp] {
        let filter = "contains(displayName, '\(query)')"
        return try await getMobileApps(filter: filter, limit: limit)
    }
    
    /// Assign an app to a group (which triggers install on group devices)
    public func assignAppToGroup(_ appId: String, groupId: String, intent: String = "required") async throws -> DeviceActionResult {
        guard let headers = await headers(for: .devices) else {
            return DeviceActionResult(success: false, deviceId: appId, action: "assignApp", message: "Not authenticated")
        }
        
        let url = "\(baseUrl)/deviceAppManagement/mobileApps/\(appId)/assign"
        let body: [String: Any] = [
            "mobileAppAssignments": [
                [
                    "target": [
                        "@odata.type": "#microsoft.graph.groupAssignmentTarget",
                        "groupId": groupId
                    ],
                    "intent": intent
                ]
            ]
        ]
        
        return try await postAction(url: url, body: body, headers: headers, deviceId: appId, action: "assignApp")
    }
    
    /// Initiate on-demand remediation or proactive remediation script
    public func initiateOnDemandRemediation(_ deviceId: String, scriptId: String) async throws -> DeviceActionResult {
        guard let headers = await headers(for: .devices) else {
            return DeviceActionResult(success: false, deviceId: deviceId, action: "remediation", message: "Not authenticated")
        }
        
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/initiateOnDemandProactiveRemediation"
        let body: [String: Any] = ["scriptPolicyId": scriptId]
        
        return try await postAction(url: url, body: body, headers: headers, deviceId: deviceId, action: "remediation")
    }
    
    /// Get Windows Autopilot device info for a managed device
    public func getWindowsAutopilotDeviceIdentity(_ deviceId: String) async throws -> WindowsAutopilotDevice? {
        guard let headers = await headers(for: .devices) else { return nil }
        
        // First get the device to get the Azure AD device ID
        let device = try await getDeviceById(deviceId)
        guard let azureAdDeviceId = device?.azureADDeviceId else { return nil }
        
        let url = "\(baseUrl)/deviceManagement/windowsAutopilotDeviceIdentities?$filter=azureActiveDirectoryDeviceId eq '\(azureAdDeviceId)'"
        let response: WindowsAutopilotDevicesResponse = try await fetch(url: url, headers: headers)
        return response.value.first
    }
    
    /// Get a single device by ID
    public func getDeviceById(_ deviceId: String) async throws -> IntuneDevice? {
        guard let headers = await headers(for: .devices) else { return nil }
        
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)"
        return try await fetch(url: url, headers: headers)
    }
    
    /// Wipe a device (factory reset)
    public func wipeDevice(_ deviceId: String, keepEnrollmentData: Bool = false, keepUserData: Bool = false) async throws -> DeviceActionResult {
        guard let headers = await headers(for: .devices) else {
            return DeviceActionResult(success: false, deviceId: deviceId, action: "wipe", message: "Not authenticated")
        }
        
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/wipe"
        let body: [String: Any] = [
            "keepEnrollmentData": keepEnrollmentData,
            "keepUserData": keepUserData
        ]
        
        return try await postAction(url: url, body: body, headers: headers, deviceId: deviceId, action: "wipe")
    }
    
    /// Retire a device (remove company data)
    public func retireDevice(_ deviceId: String) async throws -> DeviceActionResult {
        guard let headers = await headers(for: .devices) else {
            return DeviceActionResult(success: false, deviceId: deviceId, action: "retire", message: "Not authenticated")
        }
        
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/retire"
        return try await postAction(url: url, headers: headers, deviceId: deviceId, action: "retire")
    }
    
    /// Post an action to the Graph API (no body)
    private func postAction(url: String, headers: HTTPHeaders, deviceId: String, action: String) async throws -> DeviceActionResult {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, headers: headers)
                .validate(statusCode: 200..<300)
                .response { response in
                    switch response.result {
                    case .success:
                        continuation.resume(returning: DeviceActionResult(success: true, deviceId: deviceId, action: action, message: nil))
                    case .failure(let error):
                        // Check if it's a 204 No Content (success for actions)
                        if response.response?.statusCode == 204 {
                            continuation.resume(returning: DeviceActionResult(success: true, deviceId: deviceId, action: action, message: nil))
                        } else {
                            continuation.resume(returning: DeviceActionResult(success: false, deviceId: deviceId, action: action, message: error.localizedDescription))
                        }
                    }
                }
        }
    }
    
    /// Post an action with body to the Graph API
    private func postAction(url: String, body: [String: Any], headers: HTTPHeaders, deviceId: String, action: String) async throws -> DeviceActionResult {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
                .validate(statusCode: 200..<300)
                .response { response in
                    switch response.result {
                    case .success:
                        continuation.resume(returning: DeviceActionResult(success: true, deviceId: deviceId, action: action, message: nil))
                    case .failure(let error):
                        if response.response?.statusCode == 204 {
                            continuation.resume(returning: DeviceActionResult(success: true, deviceId: deviceId, action: action, message: nil))
                        } else {
                            continuation.resume(returning: DeviceActionResult(success: false, deviceId: deviceId, action: action, message: error.localizedDescription))
                        }
                    }
                }
        }
    }

    // MARK: - Entra Users (uses systems service principal)

    public func getUser(_ userPrincipalNameOrId: String, includeGroups: Bool = false) async throws -> EntraUser? {
        let cacheKey = userPrincipalNameOrId.lowercased()
        if let cached = userCache[cacheKey], Date() < cached.expiry {
            return cached.user
        }

        guard let headers = await headers(for: .systems) else { return nil }

        let escapedId = userPrincipalNameOrId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userPrincipalNameOrId
        let url = "\(baseUrl)/users/\(escapedId)"

        var user: EntraUser = try await fetch(url: url, headers: headers)
        userCache[cacheKey] = (user, Date().addingTimeInterval(cacheDuration))

        if includeGroups {
            user.memberOf = try await getUserGroups(userPrincipalNameOrId)
        }

        return user
    }

    public func getUserGroups(_ userPrincipalNameOrId: String) async throws -> [EntraGroup] {
        guard let headers = await headers(for: .systems) else { return [] }

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

    public func checkGroupMembership(user userPrincipalNameOrId: String, group groupNameOrId: String) async throws -> Bool {
        guard let headers = await headers(for: .systems) else { return false }

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

    // MARK: - Entra Groups (uses systems service principal)

    public func getGroupByName(_ displayName: String) async throws -> EntraGroup? {
        let cacheKey = displayName.lowercased()
        if let cached = groupCache[cacheKey], Date() < cached.expiry {
            return cached.group
        }

        guard let headers = await headers(for: .systems) else { return nil }

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
        guard let headers = await headers(for: .systems) else { return nil }

        let url = "\(baseUrl)/groups/\(groupId)"
        return try await fetch(url: url, headers: headers)
    }

    public func getGroupMembers(_ groupNameOrId: String, limit: Int = 100) async throws -> [EntraUser] {
        guard let headers = await headers(for: .systems) else { return [] }

        // Get group ID if name was provided
        var groupId = groupNameOrId
        if UUID(uuidString: groupNameOrId) == nil {
            guard let group = try await getGroupByName(groupNameOrId) else { return [] }
            groupId = group.id ?? ""
        }

        var url = "\(baseUrl)/groups/\(groupId)/members?$top=\(min(limit, config.graphPageSize))"
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

    public func searchGroups(_ query: String, limit: Int = 50) async throws -> [EntraGroup] {
        guard let headers = await headers(for: .systems) else { return [] }

        let filter = "startswith(displayName, '\(query)')"
        let escapedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        let url = "\(baseUrl)/groups?$filter=\(escapedFilter)&$top=\(limit)"

        let response: EntraGroupListResponse = try await fetch(url: url, headers: headers)
        return response.value
    }

    /// Search users by display name or UPN prefix (partial/fuzzy search)
    public func searchUsers(_ query: String, limit: Int = 25) async throws -> [EntraUser] {
        guard let headers = await headers(for: .systems) else { return [] }

        let escapedQuery = query.replacingOccurrences(of: "'", with: "''")
        let filter = "startswith(displayName, '\(escapedQuery)') or startswith(userPrincipalName, '\(escapedQuery)') or startswith(mail, '\(escapedQuery)')"
        let escapedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        let url = "\(baseUrl)/users?$filter=\(escapedFilter)&$top=\(limit)&$select=id,displayName,userPrincipalName,mail,jobTitle,department,officeLocation"

        let response: EntraUserListResponse = try await fetch(url: url, headers: headers)
        return response.value
    }
    
    /// Get device members of a group (for device-based groups like Devices-*)
    public func getGroupDeviceMembers(_ groupNameOrId: String, limit: Int = 500) async throws -> [EntraDevice] {
        guard let headers = await headers(for: .systems) else { return [] }

        // Get group ID if name was provided
        var groupId = groupNameOrId
        if UUID(uuidString: groupNameOrId) == nil {
            guard let group = try await getGroupByName(groupNameOrId) else { return [] }
            groupId = group.id ?? ""
        }

        // Use transitive members to get all members including nested
        var url = "\(baseUrl)/groups/\(groupId)/members?$top=\(min(limit, config.graphPageSize))"
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

    // MARK: - Private Helpers

    private func fetch<T: Decodable>(url: String, headers: HTTPHeaders) async throws -> T {
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

    private func post<T: Decodable>(url: String, body: [String: Any], headers: HTTPHeaders) async throws -> T {
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
