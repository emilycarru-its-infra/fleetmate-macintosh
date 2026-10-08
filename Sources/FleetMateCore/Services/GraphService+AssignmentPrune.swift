import Foundation

// Pruning assignment rows that point at deleted groups, on Autopilot
// deployment profiles and Enrollment Status Page configurations.
//
// A deleted target group makes Autopilot profile assignment fail for devices
// that are otherwise grouped correctly, and the row stays until someone opens
// the profile and notices it greyed out. Removing the row is safe only when
// the group is really gone, so the verdict is deliberately hard to reach:
// two separate reads must both return HTTP 404, and the group must also be
// absent from the directory's deleted items, where a soft-deleted group can
// still be restored for 30 days. Anything else, including a throttled or
// failed read, leaves the row alone. Status codes come from Graph `$batch`
// responses, which carry the HTTP status of every sub-request explicitly,
// so the verdict never depends on parsing a group's body.

/// Which kind of enrollment configuration an assignment row belongs to.
public enum EnrollmentAssignmentSource: String, Codable, Sendable {
    case autopilotProfile
    case enrollmentStatusPage

    public var label: String {
        switch self {
        case .autopilotProfile: return "Autopilot profile"
        case .enrollmentStatusPage: return "Enrollment Status Page"
        }
    }
}

/// One group-targeted assignment row on an Autopilot profile or ESP.
public struct EnrollmentAssignmentRow: Codable, Sendable, Equatable {
    public let source: EnrollmentAssignmentSource
    public let configurationId: String
    public let configurationName: String
    public let assignmentId: String
    public let groupId: String
    /// True for an exclusion target, which goes stale the same way.
    public let isExclusion: Bool

    public init(source: EnrollmentAssignmentSource, configurationId: String, configurationName: String,
                assignmentId: String, groupId: String, isExclusion: Bool) {
        self.source = source
        self.configurationId = configurationId
        self.configurationName = configurationName
        self.assignmentId = assignmentId
        self.groupId = groupId
        self.isExclusion = isExclusion
    }
}

/// What two reads and a deleted-items lookup say about one target group.
public enum GroupTargetVerdict: Codable, Sendable, Equatable {
    /// The group resolves. Its rows are never touched.
    case live
    /// The group 404s but is in deleted items and can still be restored.
    case softDeleted
    /// Two 404s and absent from deleted items: the only prunable verdict.
    case gone
    /// A read failed, was throttled, or the two reads disagreed in a way
    /// that is not "it exists". Nothing is pruned on this.
    case unresolved(String)

    public var isPrunable: Bool { self == .gone }

    public var label: String {
        switch self {
        case .live: return "live"
        case .softDeleted: return "soft-deleted (restorable)"
        case .gone: return "deleted"
        case .unresolved(let reason): return "unresolved: \(reason)"
        }
    }

    /// The decision table. `nil` means the read did not happen or returned
    /// no status for this id, which counts as unresolved, never as a 404.
    public static func decide(firstRead: Int?, secondRead: Int?, deletedItemsRead: Int?) -> GroupTargetVerdict {
        guard let firstRead else { return .unresolved("no status from the first read") }
        if (200..<300).contains(firstRead) { return .live }
        guard firstRead == 404 else { return .unresolved("first read returned HTTP \(firstRead)") }

        guard let secondRead else { return .unresolved("no status from the second read") }
        if (200..<300).contains(secondRead) { return .live }
        guard secondRead == 404 else { return .unresolved("second read returned HTTP \(secondRead)") }

        guard let deletedItemsRead else { return .unresolved("no status from the deleted-items read") }
        if (200..<300).contains(deletedItemsRead) { return .softDeleted }
        guard deletedItemsRead == 404 else { return .unresolved("deleted-items read returned HTTP \(deletedItemsRead)") }
        return .gone
    }
}

/// The result of a prune check: every group-targeted row and the verdict on
/// each distinct group.
public struct AssignmentPrunePlan: Codable, Sendable {
    public let rows: [EnrollmentAssignmentRow]
    /// Keyed by lower-cased group id.
    public let verdicts: [String: GroupTargetVerdict]

    public init(rows: [EnrollmentAssignmentRow], verdicts: [String: GroupTargetVerdict]) {
        self.rows = rows
        self.verdicts = verdicts
    }

    public func verdict(for row: EnrollmentAssignmentRow) -> GroupTargetVerdict {
        verdicts[row.groupId.lowercased()] ?? .unresolved("not checked")
    }

    /// Rows whose group is confirmed gone. The only rows `--confirm` deletes.
    public var prunable: [EnrollmentAssignmentRow] {
        rows.filter { verdict(for: $0).isPrunable }
    }

    /// Rows that are not live and not prunable, for the report.
    public var held: [EnrollmentAssignmentRow] {
        rows.filter {
            let v = verdict(for: $0)
            return v != .live && !v.isPrunable
        }
    }

    /// Build a plan from the rows. The readers return an HTTP status per
    /// group id; `pause` runs between the first and second group reads so a
    /// transient outage has time to clear rather than repeating itself.
    public static func build(
        rows: [EnrollmentAssignmentRow],
        readGroups: ([String]) async throws -> [String: Int],
        readDeletedItems: ([String]) async throws -> [String: Int],
        pause: () async -> Void
    ) async throws -> AssignmentPrunePlan {
        var seen = Set<String>()
        let groupIds = rows.map { $0.groupId.lowercased() }.filter { seen.insert($0).inserted }

        let first = groupIds.isEmpty ? [:] : try await readGroups(groupIds)
        let missingOnce = groupIds.filter { first[$0] == 404 }

        var second: [String: Int] = [:]
        var deleted: [String: Int] = [:]
        if !missingOnce.isEmpty {
            await pause()
            second = try await readGroups(missingOnce)
            let missingTwice = missingOnce.filter { second[$0] == 404 }
            if !missingTwice.isEmpty {
                deleted = try await readDeletedItems(missingTwice)
            }
        }

        var verdicts: [String: GroupTargetVerdict] = [:]
        for id in groupIds {
            verdicts[id] = GroupTargetVerdict.decide(firstRead: first[id], secondRead: second[id], deletedItemsRead: deleted[id])
        }
        return AssignmentPrunePlan(rows: rows, verdicts: verdicts)
    }
}

// MARK: - Graph shapes

struct EnrollmentAssignmentTarget: Decodable {
    let odataType: String?
    let groupId: String?

    enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type"
        case groupId
    }

    /// Group and exclusion-group targets carry a group id; all-devices and
    /// all-users targets do not and are never candidates.
    var groupTarget: (groupId: String, isExclusion: Bool)? {
        guard let groupId, !groupId.isEmpty, let type = odataType?.lowercased() else { return nil }
        if type.hasSuffix(".exclusiongroupassignmenttarget") { return (groupId, true) }
        if type.hasSuffix(".groupassignmenttarget") { return (groupId, false) }
        return nil
    }
}

struct EnrollmentAssignment: Decodable {
    let id: String
    let target: EnrollmentAssignmentTarget?
}

struct EnrollmentAssignmentsResponse: Decodable {
    let value: [EnrollmentAssignment]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

struct EnrollmentConfiguration: Decodable {
    let id: String
    let displayName: String?
    let odataType: String?
    let assignments: [EnrollmentAssignment]?

    enum CodingKeys: String, CodingKey {
        case id, displayName, assignments
        case odataType = "@odata.type"
    }
}

struct EnrollmentConfigurationsResponse: Decodable {
    let value: [EnrollmentConfiguration]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

/// A `$batch` response read for status codes only. Bodies are ignored on
/// purpose: a live group's body can carry large provisioning-error blobs,
/// and inferring absence from a body's shape gives false positives.
struct StatusOnlyBatchResponse: Decodable {
    let responses: [Item]

    struct Item: Decodable {
        let id: String
        let status: Int
    }
}

extension EnrollmentConfiguration {
    func rows(source: EnrollmentAssignmentSource) -> [EnrollmentAssignmentRow] {
        (assignments ?? []).compactMap { assignment in
            guard let target = assignment.target?.groupTarget else { return nil }
            return EnrollmentAssignmentRow(
                source: source, configurationId: id, configurationName: displayName ?? id,
                assignmentId: assignment.id, groupId: target.groupId, isExclusion: target.isExclusion)
        }
    }

    /// Enrollment Status Page configurations share the collection with
    /// enrollment limits, Windows Hello and the rest.
    var isEnrollmentStatusPage: Bool {
        odataType?.lowercased().hasSuffix(".windows10enrollmentcompletionpageconfiguration") ?? false
    }
}

// MARK: - Service

public extension GraphService {

    /// Every group-targeted assignment row on every Autopilot deployment
    /// profile and Enrollment Status Page.
    func enrollmentAssignmentRows() async throws -> [EnrollmentAssignmentRow] {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        var rows: [EnrollmentAssignmentRow] = []

        // Autopilot deployment profiles are a beta resource.
        var url: String? = "\(betaBaseURL)/deviceManagement/windowsAutopilotDeploymentProfiles?$expand=assignments"
        while let next = url {
            let page: EnrollmentConfigurationsResponse = try await fetch(url: next, headers: headers)
            for profile in page.value { rows += profile.rows(source: .autopilotProfile) }
            url = page.nextLink
        }

        // ESP assignments are read per configuration, so the listing does not
        // depend on `$expand` being honoured across every configuration type.
        var espConfigs: [EnrollmentConfiguration] = []
        url = "\(betaBaseURL)/deviceManagement/deviceEnrollmentConfigurations"
        while let next = url {
            let page: EnrollmentConfigurationsResponse = try await fetch(url: next, headers: headers)
            espConfigs += page.value.filter(\.isEnrollmentStatusPage)
            url = page.nextLink
        }
        for config in espConfigs {
            var assignments: [EnrollmentAssignment] = []
            var assignmentsUrl: String? = "\(betaBaseURL)/deviceManagement/deviceEnrollmentConfigurations/\(config.id)/assignments"
            while let next = assignmentsUrl {
                let page: EnrollmentAssignmentsResponse = try await fetch(url: next, headers: headers)
                assignments += page.value
                assignmentsUrl = page.nextLink
            }
            let withAssignments = EnrollmentConfiguration(
                id: config.id, displayName: config.displayName, odataType: config.odataType, assignments: assignments)
            rows += withAssignments.rows(source: .enrollmentStatusPage)
        }
        return rows
    }

    /// Check every target group and return the plan. Reads only.
    func planEnrollmentAssignmentPrune(recheckDelay: TimeInterval = 10) async throws -> AssignmentPrunePlan {
        let rows = try await enrollmentAssignmentRows()
        return try await AssignmentPrunePlan.build(
            rows: rows,
            readGroups: { try await self.batchStatuses(ids: $0) { "/groups/\($0)?$select=id" } },
            readDeletedItems: { try await self.batchStatuses(ids: $0) { "/directory/deletedItems/\($0)?$select=id" } },
            pause: {
                guard recheckDelay > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(recheckDelay * 1_000_000_000))
            }
        )
    }

    /// Delete one assignment row. Callers pass only rows from a plan's
    /// `prunable` list.
    func deleteEnrollmentAssignment(_ row: EnrollmentAssignmentRow) async throws {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let collection: String
        switch row.source {
        case .autopilotProfile: collection = "windowsAutopilotDeploymentProfiles"
        case .enrollmentStatusPage: collection = "deviceEnrollmentConfigurations"
        }
        let url = "\(betaBaseURL)/deviceManagement/\(collection)/\(row.configurationId)/assignments/\(row.assignmentId)"
        try await deleteAction(url: url, headers: headers)
    }

    /// GET each id through `$batch`, 20 per call, and return the HTTP status
    /// Graph reports for each. An id missing from the response is absent from
    /// the result, which the verdict treats as unresolved.
    private func batchStatuses(ids: [String], path: (String) -> String) async throws -> [String: Int] {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        var statuses: [String: Int] = [:]
        for start in stride(from: 0, to: ids.count, by: 20) {
            let chunk = Array(ids[start..<min(start + 20, ids.count)])
            // Batch request ids must be unique within a call; index them and
            // map back so an id's own characters never matter.
            let requests: [[String: Any]] = chunk.enumerated().map { index, id in
                ["id": String(index), "method": "GET", "url": path(id)]
            }
            let response: StatusOnlyBatchResponse = try await post(
                url: "\(baseUrl)/$batch", body: ["requests": requests], headers: headers)
            for item in response.responses {
                guard let index = Int(item.id), chunk.indices.contains(index) else { continue }
                statuses[chunk[index]] = item.status
            }
        }
        return statuses
    }
}
