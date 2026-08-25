import Foundation

// MARK: - Directory Audit Models

/// One entry from the Entra directory audit log.
///
/// This is the only record of who or what changed a directory object. Group
/// membership and lifecycle are increasingly driven by automation, so when a
/// group disappears the useful question is not whether it exists — that is a
/// plain lookup — but which service principal removed it, and when.
public struct DirectoryAuditEvent: Codable, Identifiable, Sendable {
    public let id: String?
    public let activityDateTime: String?
    public let activityDisplayName: String?
    public let category: String?
    public let operationType: String?
    public let result: String?
    public let resultReason: String?
    public let loggedByService: String?
    public let initiatedBy: AuditInitiator?
    public let targetResources: [AuditTargetResource]?

    /// Who performed the change, as a single printable string.
    ///
    /// An audit entry carries either a user or an application, never both, and
    /// automation shows up as the application. Callers printing "the actor"
    /// should not have to know which half of the union was populated.
    public var actor: String {
        initiatedBy?.user?.userPrincipalName
            ?? initiatedBy?.user?.displayName
            ?? initiatedBy?.app?.displayName
            ?? initiatedBy?.app?.servicePrincipalName
            ?? "unknown"
    }

    /// True when the actor was an application rather than a person.
    public var actorIsApplication: Bool {
        // Unwrapped explicitly rather than chained: `initiatedBy?.user` is a
        // doubly-optional AuditUser??, so comparing it to nil tests whether
        // initiatedBy is present, not whether the user is - which reads as false
        // for exactly the app-initiated entries this is meant to identify.
        guard let initiatedBy else { return false }
        return initiatedBy.user == nil && initiatedBy.app != nil
    }

    /// The changed objects, as a single printable string.
    public var targets: String {
        guard let resources = targetResources, !resources.isEmpty else { return "-" }
        return resources.map { $0.displayName ?? $0.id ?? "-" }.joined(separator: ", ")
    }
}

public struct AuditInitiator: Codable, Sendable {
    public let user: AuditUser?
    public let app: AuditApp?
}

public struct AuditUser: Codable, Equatable, Sendable {
    public let id: String?
    public let displayName: String?
    public let userPrincipalName: String?
}

public struct AuditApp: Codable, Equatable, Sendable {
    public let appId: String?
    public let displayName: String?
    public let servicePrincipalId: String?
    public let servicePrincipalName: String?
}

public struct AuditTargetResource: Codable, Sendable {
    public let id: String?
    public let displayName: String?
    public let type: String?
}

public struct DirectoryAuditListResponse: Codable, Sendable {
    public let value: [DirectoryAuditEvent]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

// MARK: - Query construction

/// Builds the OData `$filter` for a directory audit query.
///
/// Separated from the command so it can be asserted directly. `directoryAudits`
/// answers a malformed filter with an empty collection rather than an error, and
/// "no entries" is exactly what someone investigating a deletion is afraid of
/// seeing — so the filter is tested rather than trusted because a call returned.
public enum DirectoryAuditQuery {
    public static func filter(
        target: String?,
        activity: String?,
        days: Int,
        now: Date = Date()
    ) -> String? {
        var clauses: [String] = []

        if days > 0 {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let since = now.addingTimeInterval(-Double(days) * 86_400)
            clauses.append("activityDateTime ge \(formatter.string(from: since))")
        }

        if let activity, !activity.trimmingCharacters(in: .whitespaces).isEmpty {
            clauses.append("activityDisplayName eq '\(escape(activity))'")
        }

        if let target, !target.trimmingCharacters(in: .whitespaces).isEmpty {
            // A target is given as either the object id or its display name, and
            // the caller usually holds whichever one the failure left them with.
            // Graph will not accept an `or` across two `any` lambdas, so the
            // shape is chosen from the input instead of covering both.
            if UUID(uuidString: target) != nil {
                clauses.append("targetResources/any(t: t/id eq '\(escape(target))')")
            } else {
                clauses.append("targetResources/any(t: t/displayName eq '\(escape(target))')")
            }
        }

        return clauses.isEmpty ? nil : clauses.joined(separator: " and ")
    }

    /// An unescaped apostrophe terminates the OData string literal, and the
    /// resulting filter is either rejected or silently matches nothing.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
