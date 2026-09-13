import Foundation

/// Privileged Identity Management — the `security` elevation domain.
///
/// This deliberately does NOT go through `ElevationSession`, and the reason is the
/// whole point of the type. Elevation runs a per-domain *managed identity*: a
/// service principal. A PIM activation is a statement about a **user** — "activate
/// this eligible role for the person asking" — so a service principal cannot make
/// it on their behalf. Routing it through the container returns the same
/// missing-role refusal the operator started with.
///
/// So the security domain calls Graph as the signed-in operator, off the same local
/// `az` session the other resource tokens use. The privilege still comes from the
/// operator's own PIM eligibility; the app is not a privilege, which matches the
/// model the elevation session documents for the other five domains.
///
/// Worked example: minting a bulk device-join token for silent directory join is
/// refused unless the caller holds a device- or endpoint-admin role. Those roles
/// are PIM-eligible rather than standing, so without a way to activate one the
/// whole unattended-join path is blocked.
public struct PimRole: Codable, Sendable {
    public let roleDefinitionId: String
    public let displayName: String
    public let directoryScopeId: String
    /// Nil means permanent eligibility, or an activation with no fixed end.
    public let endDateTime: String?
}

public struct PimActivationResult: Codable, Sendable {
    public let roleName: String
    /// Graph's request status. `Provisioned` is active; anything else — notably
    /// `PendingApproval` — is not, and must not be reported as success.
    public let status: String
    public let endDateTime: String?

    public var isActive: Bool {
        status.caseInsensitiveCompare("Provisioned") == .orderedSame
            || status.caseInsensitiveCompare("AlreadyActive") == .orderedSame
    }
}

public enum PimError: LocalizedError {
    case graph(String)
    case notEligible(role: String, eligible: [String])
    case notActive(role: String)
    case justificationRequired

    public var errorDescription: String? {
        switch self {
        case .graph(let detail):
            return detail
        case .notEligible(let role, let eligible):
            let names = eligible.isEmpty
                ? "(none — you hold no PIM eligibilities)"
                : eligible.joined(separator: ", ")
            return "'\(role)' is not among your eligible roles. Eligible: \(names)"
        case .notActive(let role):
            return "'\(role)' is not currently active for you."
        case .justificationRequired:
            return "A justification is required — tenant PIM policy records it in the audit log."
        }
    }
}

public actor PimService {
    private static let graphBase = "https://graph.microsoft.com/v1.0/"

    // Named delegated scopes, not a bare resource. PIM is not in the default
    // consented set, so a resource-wide token comes back without it and Graph
    // refuses with PermissionScopeNotGranted.
    private static let readScope  = "https://graph.microsoft.com/RoleManagement.Read.Directory"
    private static let writeScope = "https://graph.microsoft.com/RoleAssignmentSchedule.ReadWrite.Directory"
    private static let meScope    = "https://graph.microsoft.com/User.Read"

    private let tokens: AzTokenSource
    private let session: URLSession

    public init(tokens: AzTokenSource = .shared, session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    private func request(_ method: String, _ path: String, scope: String, body: Data? = nil) async throws -> Data {
        let token = try await tokens.token(forScope: scope)
        guard let url = URL(string: Self.graphBase + path) else {
            throw PimError.graph("Could not build a Graph URL for \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw PimError.graph("No HTTP response from Graph")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PimError.graph(Self.readError(data, status: http.statusCode))
        }
        return data
    }

    /// Graph nests the useful sentence; surfacing the raw envelope helps nobody.
    private static func readError(_ data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "HTTP \(status)" : raw
    }

    /// The signed-in operator's directory object id.
    public func myId() async throws -> String {
        let data = try await request("GET", "me?$select=id", scope: Self.meScope)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            throw PimError.graph("Graph returned no id for the signed-in user")
        }
        return id
    }

    private func roles(_ resource: String) async throws -> [PimRole] {
        let me = try await myId()
        let path = "roleManagement/directory/\(resource)?$filter=principalId eq '\(me)'&$expand=roleDefinition"
        let data = try await request("GET", path, scope: Self.readScope)

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = obj["value"] as? [[String: Any]] else { return [] }

        return values.map { item in
            let def = item["roleDefinition"] as? [String: Any]
            return PimRole(
                roleDefinitionId: item["roleDefinitionId"] as? String ?? "",
                displayName: def?["displayName"] as? String ?? "",
                directoryScopeId: item["directoryScopeId"] as? String ?? "/",
                endDateTime: item["endDateTime"] as? String)
        }
    }

    /// Roles the operator is eligible to activate. An empty list is a real answer,
    /// not an error: it means no PIM eligibility, which is exactly what an operator
    /// hitting a missing-role failure needs to be told plainly.
    public func eligibleRoles() async throws -> [PimRole] {
        try await roles("roleEligibilityScheduleInstances")
    }

    /// Roles currently active, so a second activation is not attempted.
    public func activeRoles() async throws -> [PimRole] {
        try await roles("roleAssignmentScheduleInstances")
    }

    /// Self-activate an eligible role. `justification` is required by most tenant
    /// policies and is recorded in the audit log, so it is not optional here.
    public func activate(
        role roleName: String,
        justification: String,
        durationHours: Int = 8
    ) async throws -> PimActivationResult {
        guard !justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PimError.justificationRequired
        }

        let eligible = try await eligibleRoles()
        guard let match = eligible.first(where: { $0.displayName.caseInsensitiveCompare(roleName) == .orderedSame }) else {
            throw PimError.notEligible(role: roleName, eligible: eligible.map(\.displayName))
        }

        if let already = try await activeRoles().first(where: { $0.roleDefinitionId == match.roleDefinitionId }) {
            return PimActivationResult(roleName: match.displayName, status: "AlreadyActive", endDateTime: already.endDateTime)
        }

        let me = try await myId()
        let payload: [String: Any] = [
            "action": "selfActivate",
            "principalId": me,
            "roleDefinitionId": match.roleDefinitionId,
            "directoryScopeId": match.directoryScopeId,
            "justification": justification,
            "scheduleInfo": [
                "startDateTime": ISO8601DateFormatter().string(from: Date()),
                "expiration": ["type": "afterDuration", "duration": "PT\(durationHours)H"]
            ]
        ]

        let data = try await request(
            "POST", "roleManagement/directory/roleAssignmentScheduleRequests",
            scope: Self.writeScope,
            body: try JSONSerialization.data(withJSONObject: payload))

        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = obj?["status"] as? String ?? "Unknown"

        // A tenant that requires approval returns a pending request rather than an
        // active role. Reporting "activated" there would be a lie the operator only
        // discovers when the next call is still refused.
        return PimActivationResult(roleName: match.displayName, status: status, endDateTime: nil)
    }

    /// Give a role back early rather than waiting for it to expire.
    @discardableResult
    public func deactivate(role roleName: String) async throws -> String {
        let active = try await activeRoles()
        guard let match = active.first(where: { $0.displayName.caseInsensitiveCompare(roleName) == .orderedSame }) else {
            throw PimError.notActive(role: roleName)
        }

        let me = try await myId()
        let payload: [String: Any] = [
            "action": "selfDeactivate",
            "principalId": me,
            "roleDefinitionId": match.roleDefinitionId,
            "directoryScopeId": match.directoryScopeId,
            "justification": "Deactivated via FleetMate"
        ]

        _ = try await request(
            "POST", "roleManagement/directory/roleAssignmentScheduleRequests",
            scope: Self.writeScope,
            body: try JSONSerialization.data(withJSONObject: payload))

        return match.displayName
    }
}
