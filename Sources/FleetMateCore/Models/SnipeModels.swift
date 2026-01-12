import Foundation

// MARK: - API Response Wrappers

struct SnipeListResponse<T: Decodable>: Decodable {
    let total: Int
    let rows: [T]
}

struct SnipeResponse: Decodable {
    let status: String
    let messages: String?
    let payload: SnipeAsset?
}

// MARK: - Core Models

struct SnipeAsset: Codable, Identifiable {
    let id: Int
    let name: String?
    let assetTag: String?
    let serial: String?
    let model: SnipeModelRef?
    let statusLabel: SnipeStatusRef?
    let category: SnipeCategoryRef?
    let manufacturer: SnipeManufacturerRef?
    let location: SnipeLocationRef?
    let rtdLocation: SnipeLocationRef?
    let assignedTo: SnipeAssignedTo?
    let purchaseDate: SnipeDateRef?
    let lastCheckout: SnipeDateRef?
    let lastAuditDate: String?
    let nextAuditDate: String?
    let notes: String?
    let createdAt: SnipeDateRef?
    let updatedAt: SnipeDateRef?
    let customFields: [String: SnipeCustomField]?
    
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
}

struct SnipeUser: Codable, Identifiable {
    let id: Int
    let avatar: String?
    let firstName: String?
    let lastName: String?
    let username: String?
    let email: String?
    let employeeNum: String?
    let department: SnipeDepartmentRef?
    let location: SnipeLocationRef?
    let manager: SnipeManagerRef?
    let groups: SnipeGroupsRef?
    let activated: Bool?
    let assetsCount: Int?
    let licensesCount: Int?
    let accessoriesCount: Int?
    let consumablesCount: Int?
    let createdAt: SnipeDateRef?
    let updatedAt: SnipeDateRef?
    
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
    
    var fullName: String {
        [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }
}

struct SnipeLocation: Codable, Identifiable {
    let id: Int
    let name: String?
    let address: String?
    let address2: String?
    let city: String?
    let state: String?
    let country: String?
    let zip: String?
    let parent: SnipeLocationRef?
    let manager: SnipeManagerRef?
    let assetsCount: Int?
    let assignedAssetsCount: Int?
    let usersCount: Int?
    let createdAt: SnipeDateRef?
    let updatedAt: SnipeDateRef?
    
    enum CodingKeys: String, CodingKey {
        case id, name, address, address2, city, state, country, zip, parent, manager
        case assetsCount = "assets_count"
        case assignedAssetsCount = "assigned_assets_count"
        case usersCount = "users_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct SnipeModel: Codable, Identifiable {
    let id: Int
    let name: String?
    let manufacturer: SnipeManufacturerRef?
    let category: SnipeCategoryRef?
    let modelNumber: String?
    let eol: Int?
    let assetsCount: Int?
    let createdAt: SnipeDateRef?
    let updatedAt: SnipeDateRef?
    
    enum CodingKeys: String, CodingKey {
        case id, name, manufacturer, category, eol
        case modelNumber = "model_number"
        case assetsCount = "assets_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct SnipeCategory: Codable, Identifiable {
    let id: Int
    let name: String?
    let categoryType: String?
    let eula: Bool?
    let checkinEmail: Bool?
    let requireAcceptance: Bool?
    let itemCount: Int?
    let assetsCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case id, name, eula
        case categoryType = "category_type"
        case checkinEmail = "checkin_email"
        case requireAcceptance = "require_acceptance"
        case itemCount = "item_count"
        case assetsCount = "assets_count"
    }
}

struct SnipeStatusLabel: Codable, Identifiable {
    let id: Int
    let name: String?
    let statusType: String?
    let statusMeta: String?
    let notes: String?
    let assetsCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case statusType = "status_type"
        case statusMeta = "status_meta"
        case assetsCount = "assets_count"
    }
}

// MARK: - Reference Types (Embedded Objects)

struct SnipeModelRef: Codable {
    let id: Int?
    let name: String?
}

struct SnipeStatusRef: Codable {
    let id: Int?
    let name: String?
    let statusType: String?
    let statusMeta: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case statusType = "status_type"
        case statusMeta = "status_meta"
    }
}

struct SnipeCategoryRef: Codable {
    let id: Int?
    let name: String?
}

struct SnipeManufacturerRef: Codable {
    let id: Int?
    let name: String?
}

struct SnipeLocationRef: Codable {
    let id: Int?
    let name: String?
}

struct SnipeAssignedTo: Codable {
    let id: Int?
    let username: String?
    let name: String?
    let firstName: String?
    let lastName: String?
    let email: String?
    let employeeNumber: String?
    let type: String?
    
    enum CodingKeys: String, CodingKey {
        case id, username, name, email, type
        case firstName = "first_name"
        case lastName = "last_name"
        case employeeNumber = "employee_number"
    }
}

struct SnipeDepartmentRef: Codable {
    let id: Int?
    let name: String?
}

struct SnipeManagerRef: Codable {
    let id: Int?
    let name: String?
}

struct SnipeGroupsRef: Codable {
    let total: Int?
    let rows: [SnipeGroupRef]?
}

struct SnipeGroupRef: Codable {
    let id: Int?
    let name: String?
}

struct SnipeDateRef: Codable {
    let datetime: String?
    let formatted: String?
}

struct SnipeCustomField: Codable {
    let field: String?
    let value: String?
    let fieldFormat: String?
    
    enum CodingKeys: String, CodingKey {
        case field, value
        case fieldFormat = "field_format"
    }
}

// MARK: - Request Models

struct SnipeCheckoutRequest: Encodable {
    let assignedUser: Int?
    let assignedAsset: Int?
    let assignedLocation: Int?
    let expectedCheckin: String?
    let checkoutAt: String?
    let name: String?
    let note: String?
    
    enum CodingKeys: String, CodingKey {
        case name, note
        case assignedUser = "assigned_user"
        case assignedAsset = "assigned_asset"
        case assignedLocation = "assigned_location"
        case expectedCheckin = "expected_checkin"
        case checkoutAt = "checkout_at"
    }
    
    init(assignedUser: Int? = nil, assignedAsset: Int? = nil, assignedLocation: Int? = nil,
         expectedCheckin: String? = nil, checkoutAt: String? = nil, name: String? = nil, note: String? = nil) {
        self.assignedUser = assignedUser
        self.assignedAsset = assignedAsset
        self.assignedLocation = assignedLocation
        self.expectedCheckin = expectedCheckin
        self.checkoutAt = checkoutAt
        self.name = name
        self.note = note
    }
}

struct SnipeCheckinRequest: Encodable {
    let name: String?
    let note: String?
    let locationId: Int?
    let status: Int?
    
    enum CodingKeys: String, CodingKey {
        case name, note, status
        case locationId = "location_id"
    }
    
    init(name: String? = nil, note: String? = nil, locationId: Int? = nil, status: Int? = nil) {
        self.name = name
        self.note = note
        self.locationId = locationId
        self.status = status
    }
}

struct SnipeAuditRequest: Encodable {
    let assetTag: String?
    let locationId: Int?
    let nextAuditDate: String?
    let note: String?
    
    enum CodingKeys: String, CodingKey {
        case note
        case assetTag = "asset_tag"
        case locationId = "location_id"
        case nextAuditDate = "next_audit_date"
    }
    
    init(assetTag: String? = nil, locationId: Int? = nil, nextAuditDate: String? = nil, note: String? = nil) {
        self.assetTag = assetTag
        self.locationId = locationId
        self.nextAuditDate = nextAuditDate
        self.note = note
    }
}
