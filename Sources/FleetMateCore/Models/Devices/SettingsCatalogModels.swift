import Foundation

// MARK: - Settings Catalog Models

/// One setting definition from the Intune Settings Catalog.
///
/// A configuration profile references settings by definition id. Graph does not
/// resolve a wrong id to anything helpful — it rejects the whole profile with
/// "Setting Id is not found in the Settings Catalog" — so the id has to be right
/// before the profile is written, and the catalog is the only place to look it up.
public struct SettingsCatalogDefinition: Codable, Identifiable, Sendable {
    public let id: String
    public let displayName: String?
    public let description: String?
    public let categoryId: String?
    public let helpText: String?
    public let keywords: [String]?
    public let applicability: SettingApplicability?

    /// The `@odata.type`, which is what tells a caller the SHAPE of the value the
    /// setting takes — choice, simple, group collection. A profile supplying the
    /// right id with the wrong value shape is rejected just as firmly as one with
    /// a bad id, so this is part of the answer rather than decoration.
    public let odataType: String?

    enum CodingKeys: String, CodingKey {
        case id, displayName, description, categoryId, helpText, keywords, applicability
        case odataType = "@odata.type"
    }

    /// The value shape, with the Graph type prefix stripped.
    public var kind: String {
        guard let odataType, !odataType.isEmpty else { return "-" }
        return odataType
            .replacingOccurrences(of: "#microsoft.graph.deviceManagementConfiguration", with: "")
            .replacingOccurrences(of: "SettingDefinition", with: "")
    }

    /// Whether this definition matches a free-text query.
    ///
    /// The id is searched as well as the prose. Someone who already holds an id
    /// and wants to know whether it is real is the most common reason to search
    /// this catalog at all, so an exact id must match as readily as a word from a
    /// description. Every term has to appear somewhere, so a two-word query
    /// narrows rather than widens.
    public func matches(query: String?) -> Bool {
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }

        let haystack = [
            id,
            displayName ?? "",
            description ?? "",
            categoryId ?? "",
            (keywords ?? []).joined(separator: " ")
        ].joined(separator: " ").lowercased()

        return query
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
            .allSatisfy { haystack.contains($0) }
    }
}

public struct SettingApplicability: Codable, Sendable {
    public let platform: String?
    public let deviceMode: String?
    public let technologies: String?
}

public struct SettingsCatalogListResponse: Codable, Sendable {
    public let value: [SettingsCatalogDefinition]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}
