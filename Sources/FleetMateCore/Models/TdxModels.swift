import Foundation

// MARK: - Ticket Models

struct TdxTicket: Codable {
    let id: Int?
    let title: String?
    let description: String?
    let statusId: Int?
    let statusName: String?
    let typeId: Int?
    let typeName: String?
    let priorityId: Int?
    let priorityName: String?
    let requestorName: String?
    let requestorEmail: String?
    let requestorUid: String?
    let responsibleFullName: String?
    let responsibleEmail: String?
    let responsibleUid: String?
    let createdDate: String?
    let modifiedDate: String?
    let goesOffHoldDate: String?
    let respondByDate: String?
    let slaViolated: Bool?
    let isOnHold: Bool?
    let accountName: String?
    let sourceId: Int?
    let sourceName: String?
    let uri: String?

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

struct TdxFeedEntry: Codable {
    let id: Int?
    let body: String?
    let isPrivate: Bool?
    let createdDate: String?
    let createdFullName: String?
    let createdEmail: String?
    let itemType: Int?

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

struct TicketSearchRequest: Codable {
    var searchText: String?
    var statusIds: [Int]?
    var typeIds: [Int]?
    var priorityIds: [Int]?
    var responsibleUids: [String]?
    var requestorUids: [String]?
    var isOnHold: Bool?
    var maxResults: Int = 50

    enum CodingKeys: String, CodingKey {
        case searchText = "SearchText"
        case statusIds = "StatusIDs"
        case typeIds = "TypeIDs"
        case priorityIds = "PriorityIDs"
        case responsibleUids = "ResponsibleUids"
        case requestorUids = "RequestorUids"
        case isOnHold = "IsOnHold"
        case maxResults = "MaxResults"
    }
}

struct CreateTicketRequest: Codable {
    var typeId: Int
    var title: String
    var description: String?
    var accountId: Int?
    var statusId: Int?
    var priorityId: Int?
    var sourceId: Int?
    var requestorUid: String?
    var responsibleUid: String?

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

struct CreateFeedEntryRequest: Codable {
    var comments: String
    var isPrivate: Bool = false
    var isRichHtml: Bool = false
    var notify: [String]?

    enum CodingKeys: String, CodingKey {
        case comments = "Comments"
        case isPrivate = "IsPrivate"
        case isRichHtml = "IsRichHtml"
        case notify = "Notify"
    }
}

// MARK: - Reference Data

struct TdxStatusItem: Codable {
    let id: Int
    let name: String?
    let statusClass: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case statusClass = "StatusClass"
    }
}

struct TdxTypeItem: Codable {
    let id: Int
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
    }
}

struct TdxPriorityItem: Codable {
    let id: Int
    let name: String?
    let order: Double?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case order = "Order"
    }
}
