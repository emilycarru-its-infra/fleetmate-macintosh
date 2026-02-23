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
    public let goesOffHoldDate: String?
    public let respondByDate: String?
    public let slaViolated: Bool?
    public let isOnHold: Bool?
    public let appId: Int?
    public let parentId: Int?
    public let locationId: Int?
    public let locationRoomId: Int?
    public let uri: String?

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
        case goesOffHoldDate = "GoesOffHoldDate"
        case respondByDate = "RespondByDate"
        case slaViolated = "SlaViolated"
        case isOnHold = "IsOnHold"
        case appId = "AppID"
        case parentId = "ParentID"
        case locationId = "LocationID"
        case locationRoomId = "LocationRoomID"
        case uri = "Uri"
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
    public let replies: [TdxFeedEntry]?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case body = "Body"
        case isPrivate = "IsPrivate"
        case createdDate = "CreatedDate"
        case createdFullName = "CreatedFullName"
        case createdEmail = "CreatedEmail"
        case itemType = "ItemType"
        case replies = "Replies"
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
    public var accountId: Int?
    public var statusId: Int?
    public var priorityId: Int?
    public var sourceId: Int?
    public var requestorUid: String?
    public var responsibleUid: String?

    public init(
        typeId: Int,
        title: String,
        description: String? = nil,
        accountId: Int? = nil,
        statusId: Int? = nil,
        priorityId: Int? = nil,
        sourceId: Int? = nil,
        requestorUid: String? = nil,
        responsibleUid: String? = nil
    ) {
        self.typeId = typeId
        self.title = title
        self.description = description
        self.accountId = accountId
        self.statusId = statusId
        self.priorityId = priorityId
        self.sourceId = sourceId
        self.requestorUid = requestorUid
        self.responsibleUid = responsibleUid
    }

    enum CodingKeys: String, CodingKey {
        case typeId = "TypeID"
        case title = "Title"
        case description = "Description"
        case accountId = "AccountID"
        case statusId = "StatusID"
        case priorityId = "PriorityID"
        case sourceId = "SourceID"
        case requestorUid = "RequestorUid"
        case responsibleUid = "ResponsibleUid"
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
    public let statusClass: String?

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
