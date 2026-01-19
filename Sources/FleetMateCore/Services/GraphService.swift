import Foundation
import Alamofire

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
        guard let token = try? await getAccessToken() else { return nil }
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }

    // MARK: - Intune Devices

    public func getManagedDevices(filter: String? = nil, limit: Int = 100) async throws -> [IntuneDevice] {
        guard let headers = await headers() else { return [] }

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
        guard let headers = await headers() else { return [] }

        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)/deviceCompliancePolicyStates"
        let response: CompliancePolicyStatesResponse = try await fetch(url: url, headers: headers)
        return response.value
    }

    public func getNonCompliantDevices(limit: Int = 100) async throws -> [IntuneDevice] {
        let filter = "complianceState eq 'noncompliant'"
        return try await getManagedDevices(filter: filter, limit: limit)
    }

    // MARK: - Entra Users

    public func getUser(_ userPrincipalNameOrId: String, includeGroups: Bool = false) async throws -> EntraUser? {
        let cacheKey = userPrincipalNameOrId.lowercased()
        if let cached = userCache[cacheKey], Date() < cached.expiry {
            return cached.user
        }

        guard let headers = await headers() else { return nil }

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
        guard let headers = await headers() else { return [] }

        let filter = "startswith(displayName, '\(query)')"
        let escapedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        let url = "\(baseUrl)/groups?$filter=\(escapedFilter)&$top=\(limit)"

        let response: EntraGroupListResponse = try await fetch(url: url, headers: headers)
        return response.value
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
