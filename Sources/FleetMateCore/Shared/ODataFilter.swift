import Foundation

/// The one place user input becomes part of a Microsoft Graph `$filter`.
///
/// Two separate hazards, handled separately:
/// - inside the OData expression, a value is a single-quoted string literal, so
///   a quote in the value would close the literal and let the rest of the input
///   become filter syntax (`x' or true or deviceName eq '`) — `literal` doubles
///   every single quote, which is OData's escape;
/// - in the URL, `.urlQueryAllowed` leaves `&`, `=`, `+` and `#` alone, so an
///   encoded filter could still start a new query parameter — `encode` keeps
///   only RFC 3986 unreserved characters.
public enum ODataFilter {
    /// A value as an OData string literal, quotes included.
    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// `field eq 'value'`, with the value escaped.
    public static func equals(_ field: String, _ value: String) -> String {
        "\(field) eq \(literal(value))"
    }

    /// Percent-encode a complete filter expression for a query string.
    public static func encode(_ filter: String) -> String {
        filter.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// RFC 3986 unreserved characters: everything else is encoded.
    static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Why an identifier was refused before any request was made.
public struct DeviceIdentifierError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A validated device identifier: a serial number or a Graph object GUID.
/// Destructive commands accept nothing else, so a typo or a pasted fragment is
/// refused instead of being interpreted.
public enum DeviceIdentifier: Equatable, Sendable {
    case serial(String)
    case guid(String)

    public var value: String {
        switch self {
        case .serial(let s), .guid(let s): return s
        }
    }

    /// Hardware serials are letters and digits. Some vendors add a hyphen, so a
    /// single interior hyphen run is allowed; nothing else is.
    public static func validateSerial(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(s.count),
              s.range(of: #"^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw DeviceIdentifierError("'\(raw)' is not a valid serial number: use letters and digits only.")
        }
        return s
    }

    /// A Graph object id or deviceId: 8-4-4-4-12 hex.
    public static func validateGuid(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                      options: .regularExpression) != nil else {
            throw DeviceIdentifierError("'\(raw)' is not a valid id: expected a GUID such as 00000000-0000-0000-0000-000000000000.")
        }
        return s.lowercased()
    }

    /// GUID if it parses as one, otherwise a validated serial.
    public static func parse(_ raw: String) throws -> DeviceIdentifier {
        if let guid = try? validateGuid(raw) { return .guid(guid) }
        do {
            return .serial(try validateSerial(raw))
        } catch {
            throw DeviceIdentifierError("'\(raw)' is neither a serial number (letters and digits) nor a GUID id.")
        }
    }
}

/// The outcome of resolving an identifier for a destructive action: exactly one
/// record, or a refusal that names what was (or was not) found.
public enum ExactMatch<Record> {
    case none
    case one(Record)
    case many([Record])

    /// Reduce candidate records to an exact match on `key`, compared
    /// case-insensitively. Anything else the server returned is discarded.
    public static func resolve(_ candidates: [Record], matching value: String, by key: (Record) -> String?) -> ExactMatch<Record> {
        let exact = candidates.filter { key($0)?.caseInsensitiveCompare(value) == .orderedSame }
        switch exact.count {
        case 0: return .none
        case 1: return .one(exact[0])
        default: return .many(exact)
        }
    }

    public var single: Record? {
        if case .one(let record) = self { return record }
        return nil
    }
}
