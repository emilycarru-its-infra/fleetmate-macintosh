import Foundation
import UniformTypeIdentifiers

/// A `multipart/form-data` body carrying one file, the shape TDX's attachment
/// upload expects: a single part named `file` with the original filename.
///
/// Built by hand rather than through Alamofire's encoder so the exact bytes on
/// the wire can be pinned by a unit test without a network round trip.
public struct TdxMultipartForm: Equatable, Sendable {
    public let boundary: String
    public let body: Data

    /// The `Content-Type` header value that names this body's boundary.
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public init(
        fileName: String,
        data: Data,
        mimeType: String? = nil,
        fieldName: String = "file",
        boundary: String = "FleetMate-\(UUID().uuidString)"
    ) {
        self.boundary = boundary
        let name = Self.sanitizedFileName(fileName)
        let type = mimeType ?? Self.mimeType(forFileName: name)

        var body = Data()
        body.append("--\(boundary)\r\n")
        // RFC 7578: a filename outside ASCII travels percent-encoded in
        // `filename*`, with a plain ASCII fallback for older parsers.
        if name.canBeConverted(to: .ascii) {
            body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(Self.quoted(name))\"\r\n")
        } else {
            let fallback = String(name.unicodeScalars.map { $0.isASCII ? Character($0) : "_" })
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .rfc5987Allowed) ?? fallback
            body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(Self.quoted(fallback))\"; filename*=UTF-8''\(encoded)\r\n")
        }
        body.append("Content-Type: \(type)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        self.body = body
    }

    /// The MIME type for a filename's extension, or a generic binary type.
    public static func mimeType(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    /// Strip path components and line breaks: a header value must stay on its
    /// own line, and TDX should only ever see the leaf name.
    static func sanitizedFileName(_ fileName: String) -> String {
        let leaf = (fileName as NSString).lastPathComponent
        let cleaned = leaf.components(separatedBy: .newlines).joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

private extension CharacterSet {
    /// `attr-char` from RFC 5987.
    static let rfc5987Allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        set.insert(charactersIn: "!#$&+-.^_`|~")
        return set
    }()
}

/// Why one file did not reach the ticket, phrased for the person who chose it.
public struct TdxUploadError: LocalizedError {
    public let fileName: String
    public let statusCode: Int
    public let detail: String
    public let underlying: Error?

    public init(fileName: String, statusCode: Int, detail: String = "", underlying: Error? = nil) {
        self.fileName = fileName
        self.statusCode = statusCode
        self.detail = detail
        self.underlying = underlying
    }

    public var errorDescription: String? {
        let reason: String
        switch statusCode {
        case 0: reason = underlying?.localizedDescription ?? "the connection failed"
        case 401: reason = "the TeamDynamix session has expired"
        case 403: reason = "you don't have permission to attach files to this ticket"
        case 413: reason = "the file is larger than TeamDynamix accepts"
        case 415: reason = "TeamDynamix doesn't accept this file type"
        case 429: reason = "TeamDynamix is rate-limiting uploads; try again in a minute"
        default:
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            reason = trimmed.isEmpty || trimmed.count > 200 ? "TeamDynamix answered \(statusCode)" : trimmed
        }
        return "\(fileName): \(reason)"
    }
}

extension CharacterSet {
    /// Characters left as-is inside one query value: `&`, `=`, `+` and `#`
    /// would otherwise end the value or change its meaning.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?")
        return set
    }()
}
