import Foundation

extension String {
    /// Decode common HTML entities (e.g. &amp;quot; → ")
    public var htmlDecoded: String {
        var result = self
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&#x27;", "'"), ("&#x2F;", "/"), ("&nbsp;", " "),
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}

// MARK: - API Response Wrappers

public struct SnipeListResponse<T: Decodable>: Decodable, Sendable where T: Sendable {
    public let total: Int
    public let rows: [T]
}

public struct SnipeResponse: Decodable {
    public let status: String
    public let messages: String?
    public let payload: SnipeAsset?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        payload = try? container.decodeIfPresent(SnipeAsset.self, forKey: .payload)
        // Snipe-IT returns messages as a String on success/simple errors,
        // or as a [String: [String]] dictionary for validation errors (e.g. 422)
        if let s = try? container.decodeIfPresent(String.self, forKey: .messages) {
            messages = s
        } else if let dict = try? container.decodeIfPresent([String: [String]].self, forKey: .messages) {
            messages = dict.values.flatMap { $0 }.joined(separator: "; ")
        } else {
            messages = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case status, messages, payload
    }
}

// MARK: - Core Models

public struct SnipeAsset: Codable, Identifiable, Hashable, Sendable {
    public static func == (lhs: SnipeAsset, rhs: SnipeAsset) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public let id: Int
    public let name: String?
    public let assetTag: String?
    public let serial: String?
    public let model: SnipeModelRef?
    public let statusLabel: SnipeStatusRef?
    public let category: SnipeCategoryRef?
    public let manufacturer: SnipeManufacturerRef?
    public let location: SnipeLocationRef?
    public let rtdLocation: SnipeLocationRef?
    public let assignedTo: SnipeAssignedTo?
    public let purchaseDate: SnipeDateRef?
    public let lastCheckout: SnipeDateRef?
    public let lastAuditDate: SnipeDateRef?  // Can be null, string, or object
    public let nextAuditDate: SnipeDateRef?  // Can be null, string, or object
    public let notes: String?
    public let createdAt: SnipeDateRef?
    public let updatedAt: SnipeDateRef?
    public let customFields: [String: SnipeCustomField]?
    
    enum CodingKeys: String, CodingKey {
        case id, name, serial, model, category, manufacturer, location, notes
        case assetTag = "asset_tag"
        case statusLabel = "status_label"
        case rtdLocation = "rtd_location"
        case assignedTo = "assigned_to"
        case purchaseDate = "purchase_date"
        case lastCheckout = "last_checkout"
        case lastAuditDate = "last_audit_date"
        case nextAuditDate = "next_audit_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case customFields = "custom_fields"
    }
    
    /// Name with HTML entities decoded
    public var displayName: String? { name?.htmlDecoded }

    /// Get custom field value by database column name
    func customFieldValue(_ columnName: String) -> String? {
        guard let fields = customFields else { return nil }
        for (_, field) in fields {
            if field.field == columnName {
                return field.value
            }
        }
        return nil
    }

    /// Get custom field by display name (dictionary key)
    public func customFieldByName(_ displayName: String) -> SnipeCustomField? {
        return customFields?[displayName]
    }

    /// Purchase cost (top-level field from Snipe-IT)
    public var purchaseCost: String? {
        // Try custom field first, then would need a dedicated field
        return customFieldByName("Purchase Cost")?.value
    }
}

public struct SnipeUser: Codable, Identifiable, Hashable, Sendable {
    public static func == (lhs: SnipeUser, rhs: SnipeUser) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public let id: Int
    public let avatar: String?
    public let firstName: String?
    public let lastName: String?
    public let username: String?
    public let email: String?
    public let employeeNum: String?
    public let department: SnipeDepartmentRef?
    public let location: SnipeLocationRef?
    public let manager: SnipeManagerRef?
    public let groups: SnipeGroupsRef?
    public let activated: Bool?
    public let assetsCount: Int?
    public let licensesCount: Int?
    public let accessoriesCount: Int?
    public let consumablesCount: Int?
    public let createdAt: SnipeDateRef?
    public let updatedAt: SnipeDateRef?
    
    enum CodingKeys: String, CodingKey {
        case id, avatar, username, email, department, location, manager, groups, activated
        case firstName = "first_name"
        case lastName = "last_name"
        case employeeNum = "employee_num"
        case assetsCount = "assets_count"
        case licensesCount = "licenses_count"
        case accessoriesCount = "accessories_count"
        case consumablesCount = "consumables_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    public var fullName: String {
        [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }
}

public struct SnipeLocation: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let address: String?
    public let address2: String?
    public let city: String?
    public let state: String?
    public let country: String?
    public let zip: String?
    public let parent: SnipeLocationRef?
    public let manager: SnipeManagerRef?
    public let assetsCount: Int?
    public let assignedAssetsCount: Int?
    public let usersCount: Int?
    public let createdAt: SnipeDateRef?
    public let updatedAt: SnipeDateRef?
    
    enum CodingKeys: String, CodingKey {
        case id, name, address, address2, city, state, country, zip, parent, manager
        case assetsCount = "assets_count"
        case assignedAssetsCount = "assigned_assets_count"
        case usersCount = "users_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct SnipeModel: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let manufacturer: SnipeManufacturerRef?
    public let category: SnipeCategoryRef?
    public let modelNumber: String?
    public let eol: Int?
    public let assetsCount: Int?
    public let createdAt: SnipeDateRef?
    public let updatedAt: SnipeDateRef?
    
    enum CodingKeys: String, CodingKey {
        case id, name, manufacturer, category, eol
        case modelNumber = "model_number"
        case assetsCount = "assets_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct SnipeCategory: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let categoryType: String?
    public let eula: Bool?
    public let checkinEmail: Bool?
    public let requireAcceptance: Bool?
    public let itemCount: Int?
    public let assetsCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case id, name, eula
        case categoryType = "category_type"
        case checkinEmail = "checkin_email"
        case requireAcceptance = "require_acceptance"
        case itemCount = "item_count"
        case assetsCount = "assets_count"
    }
}

public struct SnipeStatusLabel: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let statusType: String?
    public let statusMeta: String?
    public let notes: String?
    public let assetsCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case statusType = "status_type"
        case statusMeta = "status_meta"
        case assetsCount = "assets_count"
    }
}

// MARK: - Reference Types (Embedded Objects)

public struct SnipeModelRef: Codable, Sendable {
    public let id: Int?
    public let name: String?
}

public struct SnipeStatusRef: Codable, Sendable {
    public let id: Int?
    public let name: String?
    public let statusType: String?
    public let statusMeta: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case statusType = "status_type"
        case statusMeta = "status_meta"
    }
}

public struct SnipeCategoryRef: Codable, Sendable {
    public let id: Int?
    public let name: String?
}

public struct SnipeManufacturerRef: Codable, Sendable {
    public let id: Int?
    public let name: String?
}

public struct SnipeLocationRef: Codable, Sendable {
    public let id: Int?
    public let name: String?
}

public struct SnipeAssignedTo: Codable, Sendable {
    public let id: Int?
    public let username: String?
    public let name: String?
    public let firstName: String?
    public let lastName: String?
    public let email: String?
    public let employeeNumber: String?
    public let type: String?
    
    enum CodingKeys: String, CodingKey {
        case id, username, name, email, type
        case firstName = "first_name"
        case lastName = "last_name"
        case employeeNumber = "employee_number"
    }
}

public struct SnipeDepartmentRef: Codable, Sendable {
    public let id: Int?
    public let name: String?
}

public struct SnipeManagerRef: Codable, Sendable {
    public let id: Int?
    public let name: String?
}

public struct SnipeGroupsRef: Codable, Sendable {
    public let total: Int?
    public let rows: [SnipeGroupRef]?
}

public struct SnipeGroupRef: Codable, Sendable {
    public let id: Int?
    public let name: String?
}

public struct SnipeDateRef: Codable, Sendable {
    public let datetime: String?
    public let date: String?  // Some fields use "date" instead of "datetime"
    public let formatted: String?
    
    /// Returns the date value, preferring datetime over date
    public var value: String? {
        datetime ?? date
    }
}

public struct SnipeCustomField: Codable, Sendable {
    public let field: String?
    public let value: String?
    public let fieldFormat: String?
    
    enum CodingKeys: String, CodingKey {
        case field, value
        case fieldFormat = "field_format"
    }
}

// MARK: - Activity Log

public struct SnipeActivityLog: Codable, Identifiable, Sendable {
    public let id: Int
    public let admin: SnipeActivityActor?
    public let actionType: String?
    public let target: SnipeActivityActor?
    public let item: SnipeActivityItem?
    public let note: String?
    public let createdAt: SnipeDateRef?
    public let updatedAt: SnipeDateRef?

    enum CodingKeys: String, CodingKey {
        case id, admin, target, item, note
        case actionType = "action_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct SnipeActivityActor: Codable, Sendable {
    public let id: Int?
    public let name: String?
    public let type: String?
}

public struct SnipeActivityItem: Codable, Sendable {
    public let id: Int?
    public let name: String?
    public let type: String?
}

// MARK: - Request Models

public struct SnipeCheckoutRequest: Encodable {
    public let assignedUser: Int?
    public let assignedAsset: Int?
    public let assignedLocation: Int?
    public let checkoutToType: String?
    public let expectedCheckin: String?
    public let checkoutAt: String?
    public let name: String?
    public let note: String?
    
    enum CodingKeys: String, CodingKey {
        case name, note
        case assignedUser = "assigned_user"
        case assignedAsset = "assigned_asset"
        case assignedLocation = "assigned_location"
        case checkoutToType = "checkout_to_type"
        case expectedCheckin = "expected_checkin"
        case checkoutAt = "checkout_at"
    }
    
    public init(assignedUser: Int? = nil, assignedAsset: Int? = nil, assignedLocation: Int? = nil,
         checkoutToType: String? = nil, expectedCheckin: String? = nil, checkoutAt: String? = nil,
         name: String? = nil, note: String? = nil) {
        self.assignedUser = assignedUser
        self.assignedAsset = assignedAsset
        self.assignedLocation = assignedLocation
        self.checkoutToType = checkoutToType
        self.expectedCheckin = expectedCheckin
        self.checkoutAt = checkoutAt
        self.name = name
        self.note = note
    }
}

public struct SnipeCheckinRequest: Encodable {
    public let name: String?
    public let note: String?
    public let locationId: Int?
    public let status: Int?
    
    enum CodingKeys: String, CodingKey {
        case name, note, status
        case locationId = "location_id"
    }
    
    public init(name: String? = nil, note: String? = nil, locationId: Int? = nil, status: Int? = nil) {
        self.name = name
        self.note = note
        self.locationId = locationId
        self.status = status
    }
}

public struct SnipeAssetUpdateRequest: Encodable {
    public var name: String?
    public var assetTag: String?
    public var serial: String?
    public var statusId: Int?
    public var modelId: Int?
    public var notes: String?
    public var purchaseDate: String?
    public var purchaseCost: String?
    public var orderNumber: String?
    public var locationId: Int?
    public var rtdLocationId: Int?
    public var companyId: Int?

    enum CodingKeys: String, CodingKey {
        case name, serial, notes
        case assetTag = "asset_tag"
        case statusId = "status_id"
        case modelId = "model_id"
        case purchaseDate = "purchase_date"
        case purchaseCost = "purchase_cost"
        case orderNumber = "order_number"
        case locationId = "location_id"
        case rtdLocationId = "rtd_location_id"
        case companyId = "company_id"
    }

    public init(name: String? = nil, assetTag: String? = nil, serial: String? = nil,
         statusId: Int? = nil, modelId: Int? = nil, notes: String? = nil,
         purchaseDate: String? = nil, purchaseCost: String? = nil, orderNumber: String? = nil,
         locationId: Int? = nil, rtdLocationId: Int? = nil, companyId: Int? = nil) {
        self.name = name
        self.assetTag = assetTag
        self.serial = serial
        self.statusId = statusId
        self.modelId = modelId
        self.notes = notes
        self.purchaseDate = purchaseDate
        self.purchaseCost = purchaseCost
        self.orderNumber = orderNumber
        self.locationId = locationId
        self.rtdLocationId = rtdLocationId
        self.companyId = companyId
    }
}

public struct SnipeAuditRequest: Encodable {
    public let assetTag: String?
    public let locationId: Int?
    public let nextAuditDate: String?
    public let note: String?
    
    enum CodingKeys: String, CodingKey {
        case note
        case assetTag = "asset_tag"
        case locationId = "location_id"
        case nextAuditDate = "next_audit_date"
    }
    
    public init(assetTag: String? = nil, locationId: Int? = nil, nextAuditDate: String? = nil, note: String? = nil) {
        self.assetTag = assetTag
        self.locationId = locationId
        self.nextAuditDate = nextAuditDate
        self.note = note
    }
}
