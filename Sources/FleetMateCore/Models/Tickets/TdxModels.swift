import Foundation

// MARK: - Ticket Models

public struct TdxTicket: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: Int?
    public let title: String?
    public let description: String?
    public let statusId: Int?
    public let statusName: String?
    public let typeId: Int?
    public let typeName: String?
    public let classification: Int?
    public let classificationName: String?
    public let priorityId: Int?
    public let priorityName: String?
    public let urgencyId: Int?
    public let urgencyName: String?
    public let impactId: Int?
    public let impactName: String?
    public let accountId: Int?
    public let accountName: String?
    public let sourceId: Int?
    public let sourceName: String?
    public let formId: Int?
    public let formName: String?
    public let serviceId: Int?
    public let serviceName: String?
    public let serviceOfferingId: Int?
    public let serviceOfferingName: String?
    public let requestorName: String?
    public let requestorEmail: String?
    public let requestorUid: String?
    public let responsibleFullName: String?
    public let responsibleEmail: String?
    public let responsibleUid: String?
    public let responsibleGroupId: Int?
    public let responsibleGroupName: String?
    public let createdDate: String?
    public let modifiedDate: String?
    public let daysOld: Int?
    public let goesOffHoldDate: String?
    public let respondByDate: String?
    public let slaViolated: Bool?
    public let isOnHold: Bool?
    public let appId: Int?
    public let parentId: Int?
    public let parentTitle: String?
    public let parentClass: Int?
    public let locationId: Int?
    public let locationRoomId: Int?
    public let uri: String?
    public let attachments: [TdxAttachment]?

    /// Attachments as a plain array, newest first — how the web UI sorts them.
    public var attachmentList: [TdxAttachment] {
        (attachments ?? []).sorted { ($0.createdDate ?? "") > ($1.createdDate ?? "") }
    }

    /// How long the ticket has been open, in whole days.
    ///
    /// Always days, never "1 month" — for a queue, "47d" says something that
    /// "2 months ago" rounds away. TDX supplies `DaysOld` on both the single
    /// ticket and search payloads; the fallback covers responses that omit it.
    public var ageInDays: Int? {
        if let daysOld { return daysOld }
        guard let createdDate,
              let created = TdxTicket.parseDate(createdDate) else { return nil }
        return Calendar.current.dateComponents([.day], from: created, to: Date()).day
    }

    /// Compact age for a column or badge: `16d`.
    public var ageLabel: String {
        guard let days = ageInDays else { return "-" }
        return "\(days)d"
    }

    /// Days since anything last happened on the ticket.
    ///
    /// On a board card this is the more useful number than age: it answers
    /// "how long has this been sitting untouched", which is what a stalled
    /// ticket looks like. Age only says when it arrived.
    public var daysSinceLastActivity: Int? {
        guard let modifiedDate,
              let modified = TdxTicket.parseDate(modifiedDate) else { return ageInDays }
        return Calendar.current.dateComponents([.day], from: modified, to: Date()).day
    }

    public var lastActivityLabel: String {
        guard let days = daysSinceLastActivity else { return "-" }
        return "\(days)d"
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// The parent ticket's ID, or nil when the ticket has no parent.
    ///
    /// TDX reports "no parent" as `0`, not as a missing/null field, so a plain
    /// `parentId != nil` check treats every orphan as a child of ticket zero.
    public var parentTicketId: Int? {
        guard let parentId, parentId > 0 else { return nil }
        return parentId
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case title = "Title"
        case description = "Description"
        case statusId = "StatusID"
        case statusName = "StatusName"
        case typeId = "TypeID"
        case typeName = "TypeName"
        case classification = "Classification"
        case classificationName = "ClassificationName"
        case priorityId = "PriorityID"
        case priorityName = "PriorityName"
        case urgencyId = "UrgencyID"
        case urgencyName = "UrgencyName"
        case impactId = "ImpactID"
        case impactName = "ImpactName"
        case accountId = "AccountID"
        case accountName = "AccountName"
        case sourceId = "SourceID"
        case sourceName = "SourceName"
        case formId = "FormID"
        case formName = "FormName"
        case serviceId = "ServiceID"
        case serviceName = "ServiceName"
        case serviceOfferingId = "ServiceOfferingID"
        case serviceOfferingName = "ServiceOfferingName"
        case requestorName = "RequestorName"
        case requestorEmail = "RequestorEmail"
        case requestorUid = "RequestorUid"
        case responsibleFullName = "ResponsibleFullName"
        case responsibleEmail = "ResponsibleEmail"
        case responsibleUid = "ResponsibleUid"
        case responsibleGroupId = "ResponsibleGroupID"
        case responsibleGroupName = "ResponsibleGroupName"
        case createdDate = "CreatedDate"
        case modifiedDate = "ModifiedDate"
        case daysOld = "DaysOld"
        case goesOffHoldDate = "GoesOffHoldDate"
        case respondByDate = "RespondByDate"
        case slaViolated = "SlaViolated"
        case isOnHold = "IsOnHold"
        case appId = "AppID"
        case parentId = "ParentID"
        case parentTitle = "ParentTitle"
        case parentClass = "ParentClass"
        case locationId = "LocationID"
        case locationRoomId = "LocationRoomID"
        case uri = "Uri"
        case attachments = "Attachments"
    }
}

// MARK: - Attachments

/// A file on a ticket.
///
/// TDX returns these inline on the ticket itself — there is no
/// `GET /tickets/{id}/attachments` to call (that route is POST-only, for
/// uploads) — and each one carries the address of its own bytes.
public struct TdxAttachment: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let size: Int?
    public let createdFullName: String?
    public let createdDate: String?
    public let isPrivate: Bool?
    public let contentUri: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case size = "Size"
        case createdFullName = "CreatedFullName"
        case createdDate = "CreatedDate"
        case isPrivate = "IsPrivate"
        case contentUri = "ContentUri"
    }

    public var displayName: String { name ?? id }

    public var sizeLabel: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// An SF Symbol matching the file type, for the row's leading icon.
    public var iconName: String {
        switch (name as NSString?)?.pathExtension.lowercased() ?? "" {
        case "png", "jpg", "jpeg", "gif", "heic", "bmp", "tiff", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "7z": return "doc.zipper"
        case "csv", "xlsx", "xls": return "tablecells"
        case "doc", "docx", "rtf", "txt", "md": return "doc.text"
        case "mov", "mp4", "m4v", "avi": return "film"
        case "log": return "list.bullet.rectangle"
        default: return "paperclip"
        }
    }
}

// MARK: - Feed Entry (Comments)

public struct TdxFeedEntry: Codable, Identifiable, Hashable {
    public let id: Int?
    public let body: String?
    public let isPrivate: Bool?
    public let createdDate: String?
    public let createdFullName: String?
    public let createdEmail: String?
    public let itemType: Int?
    public let itemId: Int?
    public let replies: [TdxFeedEntry]?
    public let repliesCount: Int?

    /// Replies as a plain array — TDX omits the key on some entries and sends
    /// `[]` on others, and callers shouldn't have to care which.
    public var replyList: [TdxFeedEntry] { replies ?? [] }

    /// True when TDX says this entry has replies but didn't send them.
    ///
    /// The ticket feed collection always returns `Replies: []` and reports the
    /// real number in `RepliesCount`; only `GET /api/feed/{id}` carries the
    /// bodies. Rendering straight from the feed therefore shows no threads at
    /// all, which is exactly what it looked like.
    public var hasUnloadedReplies: Bool {
        (repliesCount ?? 0) > 0 && replyList.isEmpty
    }

    public init(
        id: Int?,
        body: String?,
        isPrivate: Bool?,
        createdDate: String?,
        createdFullName: String?,
        createdEmail: String?,
        itemType: Int?,
        itemId: Int?,
        replies: [TdxFeedEntry]?,
        repliesCount: Int?
    ) {
        self.id = id
        self.body = body
        self.isPrivate = isPrivate
        self.createdDate = createdDate
        self.createdFullName = createdFullName
        self.createdEmail = createdEmail
        self.itemType = itemType
        self.itemId = itemId
        self.replies = replies
        self.repliesCount = repliesCount
    }

    /// A copy carrying the given replies.
    public func withReplies(_ replies: [TdxFeedEntry]) -> TdxFeedEntry {
        TdxFeedEntry(
            id: id,
            body: body,
            isPrivate: isPrivate,
            createdDate: createdDate,
            createdFullName: createdFullName,
            createdEmail: createdEmail,
            itemType: itemType,
            itemId: itemId,
            replies: replies,
            repliesCount: repliesCount ?? replies.count
        )
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case body = "Body"
        case isPrivate = "IsPrivate"
        case createdDate = "CreatedDate"
        case createdFullName = "CreatedFullName"
        case createdEmail = "CreatedEmail"
        case itemType = "ItemType"
        case itemId = "ItemID"
        case replies = "Replies"
        case repliesCount = "RepliesCount"
    }
}

// MARK: - Request Models

public struct TicketSearchRequest: Codable {
    public var searchText: String?
    public var statusIds: [Int]?
    public var typeIds: [Int]?
    public var priorityIds: [Int]?
    public var responsibleUids: [String]?
    public var responsibleGroupIds: [Int]?
    public var requestorUids: [String]?
    public var isOnHold: Bool?
    public var createdDateFrom: String?
    public var createdDateTo: String?
    public var maxResults: Int = 50

    public init(
        searchText: String? = nil,
        statusIds: [Int]? = nil,
        typeIds: [Int]? = nil,
        priorityIds: [Int]? = nil,
        responsibleUids: [String]? = nil,
        responsibleGroupIds: [Int]? = nil,
        requestorUids: [String]? = nil,
        isOnHold: Bool? = nil,
        createdDateFrom: String? = nil,
        createdDateTo: String? = nil,
        maxResults: Int = 50
    ) {
        self.searchText = searchText
        self.statusIds = statusIds
        self.typeIds = typeIds
        self.priorityIds = priorityIds
        self.responsibleUids = responsibleUids
        self.responsibleGroupIds = responsibleGroupIds
        self.requestorUids = requestorUids
        self.isOnHold = isOnHold
        self.createdDateFrom = createdDateFrom
        self.createdDateTo = createdDateTo
        self.maxResults = maxResults
    }

    enum CodingKeys: String, CodingKey {
        case searchText = "SearchText"
        case statusIds = "StatusIDs"
        case typeIds = "TypeIDs"
        case priorityIds = "PriorityIDs"
        case responsibleUids = "ResponsibleUids"
        case responsibleGroupIds = "ResponsibleGroupIDs"
        case requestorUids = "RequestorUids"
        case isOnHold = "IsOnHold"
        case createdDateFrom = "CreatedDateFrom"
        case createdDateTo = "CreatedDateTo"
        case maxResults = "MaxResults"
    }
}

public struct CreateTicketRequest: Codable {
    public var typeId: Int
    public var title: String
    public var description: String?
    public var classification: Int?
    public var formId: Int?
    public var accountId: Int?
    public var statusId: Int?
    public var priorityId: Int?
    public var sourceId: Int?
    public var serviceId: Int?
    public var requestorUid: String?
    public var responsibleUid: String?
    public var responsibleGroupId: Int?
    public var parentId: Int?
    public var isRichHtml: Bool?

    public init(
        typeId: Int,
        title: String,
        description: String? = nil,
        classification: Int? = nil,
        formId: Int? = nil,
        accountId: Int? = nil,
        statusId: Int? = nil,
        priorityId: Int? = nil,
        sourceId: Int? = nil,
        serviceId: Int? = nil,
        requestorUid: String? = nil,
        responsibleUid: String? = nil,
        responsibleGroupId: Int? = nil,
        parentId: Int? = nil,
        isRichHtml: Bool? = nil
    ) {
        self.typeId = typeId
        self.title = title
        self.description = description
        self.classification = classification
        self.formId = formId
        self.accountId = accountId
        self.statusId = statusId
        self.priorityId = priorityId
        self.sourceId = sourceId
        self.serviceId = serviceId
        self.requestorUid = requestorUid
        self.responsibleUid = responsibleUid
        self.responsibleGroupId = responsibleGroupId
        self.parentId = parentId
        self.isRichHtml = isRichHtml
    }

    enum CodingKeys: String, CodingKey {
        case typeId = "TypeID"
        case title = "Title"
        case description = "Description"
        case classification = "Classification"
        case formId = "FormID"
        case accountId = "AccountID"
        case statusId = "StatusID"
        case priorityId = "PriorityID"
        case sourceId = "SourceID"
        case serviceId = "ServiceID"
        case requestorUid = "RequestorUid"
        case responsibleUid = "ResponsibleUid"
        case responsibleGroupId = "ResponsibleGroupID"
        case parentId = "ParentID"
        case isRichHtml = "IsRichHtml"
    }
}

/// TDX ticket classification IDs.
///
/// These are fixed platform-wide constants, not per-tenant reference data, and
/// TDX exposes no endpoint to enumerate them — hence the hard-coded list.
public enum TdxClassification: Int, CaseIterable, Sendable {
    case ticket = 9
    case incident = 32
    case problem = 33
    case change = 34
    case release = 35
    case serviceRequest = 46
    case majorIncident = 77

    public var name: String {
        switch self {
        case .ticket: return "Ticket"
        case .incident: return "Incident"
        case .problem: return "Problem"
        case .change: return "Change"
        case .release: return "Release"
        case .serviceRequest: return "Service Request"
        case .majorIncident: return "Major Incident"
        }
    }
}

/// Full update payload required by TDX POST /api/{appId}/tickets/{id}
/// TDX treats PATCH as a full replace — any field omitted gets nulled.
/// This struct echoes back every field from the existing ticket with overrides.
public struct TicketUpdateRequest: Codable {
    public var typeId: Int
    public var classification: Int?
    public var title: String
    public var description: String?
    public var accountId: Int?
    public var sourceId: Int?
    public var statusId: Int?
    public var priorityId: Int?
    public var urgencyId: Int?
    public var impactId: Int?
    public var formId: Int?
    public var serviceId: Int?
    public var serviceOfferingId: Int?
    public var requestorUid: String?
    public var responsibleUid: String?
    public var responsibleGroupId: Int?
    public var parentId: Int?
    public var locationId: Int?
    public var locationRoomId: Int?
    public var isRichHtml: Bool?

    /// Build a full update request echoing back an existing ticket, with optional overrides.
    /// isRichHtml is always true — TDX stores descriptions as HTML.
    public init(from ticket: TdxTicket,
                title: String? = nil,
                description: String? = nil,
                statusId: Int? = nil,
                priorityId: Int? = nil,
                classification: Int? = nil,
                typeId: Int? = nil,
                requestorUid: String? = nil,
                responsibleUid: String? = nil,
                responsibleGroupId: Int? = nil,
                serviceId: Int? = nil,
                formId: Int? = nil,
                parentId: Int? = nil) {
        self.typeId = typeId ?? ticket.typeId ?? 0
        self.classification = classification ?? ticket.classification
        self.title = title ?? ticket.title ?? ""
        // Always echo back the original HTML description unless explicitly overridden
        self.description = description ?? ticket.description
        self.accountId = ticket.accountId
        self.sourceId = ticket.sourceId
        self.statusId = statusId ?? ticket.statusId
        self.priorityId = priorityId ?? ticket.priorityId
        self.urgencyId = ticket.urgencyId
        self.impactId = ticket.impactId
        self.formId = formId ?? ticket.formId
        self.serviceId = serviceId ?? ticket.serviceId
        self.serviceOfferingId = ticket.serviceOfferingId
        self.requestorUid = requestorUid ?? ticket.requestorUid
        self.responsibleUid = responsibleUid ?? ticket.responsibleUid
        self.responsibleGroupId = responsibleGroupId ?? ticket.responsibleGroupId
        self.parentId = parentId ?? ticket.parentId
        self.locationId = ticket.locationId
        self.locationRoomId = ticket.locationRoomId
        // Always true — TDX descriptions are HTML; omitting this corrupts formatting
        self.isRichHtml = true
    }

    enum CodingKeys: String, CodingKey {
        case typeId = "TypeID"
        case classification = "Classification"
        case title = "Title"
        case description = "Description"
        case accountId = "AccountID"
        case sourceId = "SourceID"
        case statusId = "StatusID"
        case priorityId = "PriorityID"
        case urgencyId = "UrgencyID"
        case impactId = "ImpactID"
        case formId = "FormID"
        case serviceId = "ServiceID"
        case serviceOfferingId = "ServiceOfferingID"
        case requestorUid = "RequestorUid"
        case responsibleUid = "ResponsibleUid"
        case responsibleGroupId = "ResponsibleGroupID"
        case parentId = "ParentID"
        case locationId = "LocationID"
        case locationRoomId = "LocationRoomID"
        case isRichHtml = "IsRichHtml"
    }
}

public struct CreateFeedEntryRequest: Codable {
    public var comments: String
    public var isPrivate: Bool = false
    public var isRichHtml: Bool = false
    public var notify: [String]?

    enum CodingKeys: String, CodingKey {
        case comments = "Comments"
        case isPrivate = "IsPrivate"
        case isRichHtml = "IsRichHtml"
        case notify = "Notify"
    }
}

// MARK: - People Models

public struct TdxPerson: Codable, Identifiable, Hashable {
    public let uid: String?
    public let fullName: String?
    public let firstName: String?
    public let lastName: String?
    public let primaryEmail: String?

    public var id: String { uid ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case uid = "UID"
        case fullName = "FullName"
        case firstName = "FirstName"
        case lastName = "LastName"
        case primaryEmail = "PrimaryEmail"
    }
}

// MARK: - Reference Data

public struct TdxStatusItem: Codable {
    public let id: Int
    public let name: String?
    /// TDX sends this as a numeric enum (1 = New, 2 = In Process, …), not a
    /// name. Typed as a String it failed to decode, taking the whole status
    /// list down with it.
    public let statusClass: Int?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case statusClass = "StatusClass"
    }
}

public struct TdxTypeItem: Codable {
    public let id: Int
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
    }
}

public struct TdxPriorityItem: Codable {
    public let id: Int
    public let name: String?
    public let order: Double?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case order = "Order"
    }
}

public struct TdxFormItem: Codable {
    public let id: Int
    public let name: String?
    public let active: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case active = "Active"
    }
}

public struct TdxSourceItem: Codable {
    public let id: Int
    public let name: String?
    public let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case isActive = "IsActive"
    }
}

public struct TdxAccountItem: Codable {
    public let id: Int
    public let name: String?
    public let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case isActive = "IsActive"
    }
}

public struct TdxGroupItem: Codable {
    public let id: Int
    public let name: String?
    public let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case isActive = "IsActive"
    }
}

public struct TdxServiceItem: Codable {
    public let id: Int
    public let name: String?
    public let compositeName: String?
    public let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case compositeName = "CompositeName"
        case isActive = "IsActive"
    }
}

/// A named reference item for a picker — the shape every lookup above collapses to.
public struct TdxLookupItem: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}
