import Foundation

/// One row of an asset's history, as Snipe-IT's `/hardware/{id}/history`
/// returns it: who did what, to which target, and which fields changed.
public struct SnipeHistoryEntry: Decodable, Identifiable, Sendable {
    public let id: Int
    public let actionType: String?
    public let createdBy: SnipeActivityActor?
    public let target: SnipeActivityActor?
    public let note: String?
    public let quantity: Int?
    public let file: SnipeHistoryFile?
    public let actionDate: SnipeDateRef?
    public let createdAt: SnipeDateRef?
    /// Field changes, sorted by label so a row reads the same every time.
    public let changes: [SnipeFieldChange]

    enum CodingKeys: String, CodingKey {
        case id, admin, target, note, quantity, file
        case actionType = "action_type"
        case createdBy = "created_by"
        case actionDate = "action_date"
        case createdAt = "created_at"
        case logMeta = "log_meta"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        actionType = try? c.decodeIfPresent(String.self, forKey: .actionType)
        createdBy = (try? c.decodeIfPresent(SnipeActivityActor.self, forKey: .createdBy))
            ?? (try? c.decodeIfPresent(SnipeActivityActor.self, forKey: .admin))
        target = try? c.decodeIfPresent(SnipeActivityActor.self, forKey: .target)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        quantity = try? c.decodeIfPresent(Int.self, forKey: .quantity)
        file = try? c.decodeIfPresent(SnipeHistoryFile.self, forKey: .file)
        actionDate = try? c.decodeIfPresent(SnipeDateRef.self, forKey: .actionDate)
        createdAt = try? c.decodeIfPresent(SnipeDateRef.self, forKey: .createdAt)
        // An empty PHP array arrives as `[]`, not `{}`; either means no changes.
        let meta = (try? c.decodeIfPresent(OrderedMeta.self, forKey: .logMeta))?.entries ?? []
        changes = meta
    }

    /// When the action happened: the action date when the admin back-dated
    /// it, else when it was logged.
    public var when: SnipeDateRef? { actionDate ?? createdAt }
}

public struct SnipeHistoryFile: Decodable, Sendable {
    public let url: String?
    public let filename: String?
}

/// One changed field: a friendly label plus the old and new values, either of
/// which may be blank (a field set for the first time has no old value).
public struct SnipeFieldChange: Sendable, Hashable {
    public let field: String
    public let old: String
    public let new: String

    public init(field: String, old: String, new: String) {
        self.field = field
        self.old = old
        self.new = new
    }

    /// `_snipeit_chip_7` → `Chip`, `warranty_months` → `Warranty Months`.
    /// Labels the server already translated ("Default Location") pass through.
    public static func label(for key: String) -> String {
        var name = key
        let custom = name.hasPrefix("_snipeit_")
        if custom {
            name.removeFirst("_snipeit_".count)
            // Custom columns end in the field id: `chip_7`.
            if let range = name.range(of: #"_\d+$"#, options: .regularExpression) {
                name.removeSubrange(range)
            }
        }
        guard name.contains("_") || name == name.lowercased() else { return name }
        return name.split(separator: "_").map { word in
            let w = String(word)
            switch w.lowercased() {
            case "id": return "ID"
            case "eol": return "EOL"
            case "po": return "PO"
            case "ip": return "IP"
            case "gpu", "cpu", "imei", "byod": return w.uppercased()
            default: return w.prefix(1).uppercased() + w.dropFirst()
            }
        }.joined(separator: " ")
    }

    /// Snipe escapes values for HTML before sending them.
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// `log_meta` is an object of `{old, new}` pairs keyed by column. JSON
/// decoding does not keep key order, so the entries are sorted by label.
private struct OrderedMeta: Decodable {
    let entries: [SnipeFieldChange]

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    struct Pair: Decodable {
        let old: Scalar?
        let new: Scalar?
    }

    /// Values arrive as strings, numbers, booleans or null.
    struct Scalar: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { text = "" }
            else if let s = try? c.decode(String.self) { text = s }
            else if let i = try? c.decode(Int.self) { text = String(i) }
            else if let d = try? c.decode(Double.self) { text = String(d) }
            else if let b = try? c.decode(Bool.self) { text = b ? "Yes" : "No" }
            else { text = "" }
        }
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Key.self) else {
            entries = []
            return
        }
        var out: [SnipeFieldChange] = []
        for key in c.allKeys {
            let label = SnipeFieldChange.label(for: key.stringValue)
            if let pair = try? c.decode(Pair.self, forKey: key), pair.old != nil || pair.new != nil {
                out.append(SnipeFieldChange(field: label,
                                            old: SnipeFieldChange.clean(pair.old?.text ?? ""),
                                            new: SnipeFieldChange.clean(pair.new?.text ?? "")))
            } else if let scalar = try? c.decode(Scalar.self, forKey: key), !scalar.text.isEmpty {
                out.append(SnipeFieldChange(field: label, old: "", new: SnipeFieldChange.clean(scalar.text)))
            }
        }
        entries = out.sorted { $0.field.localizedStandardCompare($1.field) == .orderedAscending }
    }
}
