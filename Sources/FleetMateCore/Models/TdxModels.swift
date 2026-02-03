import Foundation

// MARK: - Ticket Models

public struct TdxTicket: Codable, Identifiable, Sendable {
    public let id: Int?
    public let title: String?
    public let description: String?
    public let statusId: Int?
    public let statusName: String?
    public let typeId: Int?
    public let typeName: String?
    public let priorityId: Int?
    public let priorityName: String?
    public let requestorName: String?
    public let requestorEmail: String?
    public let requestorUid: String?
    public let responsibleFullName: String?
    public let responsibleEmail: String?
    public let responsibleUid: String?
    public let createdDate: String?
    public let modifiedDate: String?
    public let goesOffHoldDate: String?
    public let respondByDate: String?
    public let slaViolated: Bool?
    public let isOnHold: Bool?
    public let accountName: String?
    public let sourceId: Int?
    public let sourceName: String?
    public let uri: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case title = "Title"
        case description = "Description"
        case statusId = "StatusID"
        case statusName = "StatusName"
        case typeId = "TypeID"
        case typeName = "TypeName"
        case priorityId = "PriorityID"
        case priorityName = "PriorityName"
        case requestorName = "RequestorName"
        case requestorEmail = "RequestorEmail"
        case requestorUid = "RequestorUid"
        case responsibleFullName = "ResponsibleFullName"
        case responsibleEmail = "ResponsibleEmail"
        case responsibleUid = "ResponsibleUid"
        case createdDate = "CreatedDate"
        case modifiedDate = "ModifiedDate"
        case goesOffHoldDate = "GoesOffHoldDate"
        case respondByDate = "RespondByDate"
        case slaViolated = "SlaViolated"
        case isOnHold = "IsOnHold"
        case accountName = "AccountName"
        case sourceId = "SourceID"
        case sourceName = "SourceName"
        case uri = "Uri"
    }
}

// MARK: - Feed Entry (Comments)

public struct TdxFeedEntry: Codable {
    public let id: Int?
    public let body: String?
    public let isPrivate: Bool?
    public let createdDate: String?
    public let createdFullName: String?
    public let createdEmail: String?
    public let itemType: Int?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case body = "Body"
        case isPrivate = "IsPrivate"
        case createdDate = "CreatedDate"
        case createdFullName = "CreatedFullName"
        case createdEmail = "CreatedEmail"
        case itemType = "ItemType"
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
