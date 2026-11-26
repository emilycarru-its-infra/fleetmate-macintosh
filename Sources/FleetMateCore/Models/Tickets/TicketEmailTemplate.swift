import Foundation

/// The subset of Mustache that TeamDynamix notification templates use:
/// `{{name}}` (HTML-escaped), `{{{name}}}` (raw), `{{#name}}…{{/name}}`
/// sections and `{{^name}}…{{/name}}` inverted sections. A section whose value
/// is a dictionary renders with that dictionary in scope, which is how TDX
/// passes custom attributes (`{{#Attribute123}}{{Name}}: {{Value}}{{/Attribute123}}`).
/// Names nobody supplied render as nothing, and their sections are skipped.
public enum MustacheRenderer {
    public static func render(_ template: String, _ context: [String: Any]) -> String {
        render(Substring(template), stack: [context])
    }

    private static func render(_ template: Substring, stack: [[String: Any]]) -> String {
        var output = ""
        var rest = template
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            let triple = afterOpen.hasPrefix("{")
            let closeToken = triple ? "}}}" : "}}"
            let tagStart = triple ? afterOpen.index(after: afterOpen.startIndex) : afterOpen.startIndex
            guard let close = afterOpen[tagStart...].range(of: closeToken) else {
                output += rest[open.lowerBound...]
                return output
            }
            let tag = afterOpen[tagStart..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            rest = afterOpen[close.upperBound...]

            if triple {
                output += string(lookup(tag, stack))
                continue
            }
            guard let sigil = tag.first else { continue }
            switch sigil {
            case "#", "^":
                let name = String(tag.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard let end = rest.range(of: "{{/\(name)}}") else { continue }
                let inner = rest[..<end.lowerBound]
                rest = rest[end.upperBound...]
                let value = lookup(name, stack)
                if sigil == "^" {
                    if !isTruthy(value) { output += render(inner, stack: stack) }
                } else if let dict = value as? [String: Any] {
                    output += render(inner, stack: stack + [dict])
                } else if let list = value as? [[String: Any]] {
                    for item in list { output += render(inner, stack: stack + [item]) }
                } else if isTruthy(value) {
                    output += render(inner, stack: stack)
                }
            case "!", "/":
                continue
            case "&":
                output += string(lookup(String(tag.dropFirst()).trimmingCharacters(in: .whitespaces), stack))
            default:
                output += escape(string(lookup(tag, stack)))
            }
        }
        output += rest
        return output
    }

    private static func lookup(_ name: String, _ stack: [[String: Any]]) -> Any? {
        for scope in stack.reversed() {
            if let value = scope[name] { return value }
        }
        return nil
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case nil: return false
        case let bool as Bool: return bool
        case let string as String: return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let list as [Any]: return !list.isEmpty
        default: return true
        }
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : ""
        case let dict as [String: Any]: return string(dict["Value"])
        default: return "\(value!)"
        }
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}

/// The organisation's TeamDynamix notification emails, installed on each Mac
/// by a managed package, used to show an Inbox comment the way its email looks.
///
/// Layout: `<root>/<appId>/<template>.html`, with `<root>/manifest.json`
/// naming the build. Nothing here ships with the app: without the package the
/// Inbox falls back to a plain rendering of the comment.
public struct TicketEmailTemplates: Sendable {
    public static let defaultRoot = URL(fileURLWithPath: "/Library/Management/Tickets/Templates", isDirectory: true)
    public static let commentAdded = "ticket_comment_added_ticketing_user"

    public let root: URL

    public init(root: URL = TicketEmailTemplates.defaultRoot) {
        self.root = root
    }

    /// The installed build, from the manifest.
    public var version: String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    public func template(_ name: String, appId: Int?) -> String? {
        guard let appId else { return nil }
        let url = root.appendingPathComponent(String(appId)).appendingPathComponent("\(name).html")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The values a comment notification fills in.
    public static func commentContext(item: TicketInboxItem, ticket: TdxTicket?, ticketUrl: String?,
                                      dateText: String) -> [String: Any] {
        var context: [String: Any] = [
            "ID": String(item.ticketId),
            "Title": ticket?.title ?? item.ticketTitle,
            "UpdateCreatedUserFullName": item.author,
            "UpdateCreatedDate": dateText,
            "UpdateText": item.body,
            "NotificationRecipients": item.notifiedList ?? "",
        ]
        if let ticketUrl { context["NextTicketsUrl"] = ticketUrl }
        if let ticket {
            context["Description"] = ticket.description ?? ""
            context["RequestorFullName"] = ticket.requestorName ?? ""
            context["AccountName"] = ticket.accountName ?? ""
            context["ClassificationName"] = ticket.classificationName ?? ""
            context["ServiceName"] = ticket.serviceName ?? ""
        }
        return context
    }

    /// The comment as its notification email, or nil when no template is installed.
    public func commentEmail(item: TicketInboxItem, ticket: TdxTicket?, appId: Int?,
                             ticketUrl: String?, dateText: String) -> String? {
        guard let template = template(Self.commentAdded, appId: appId) else { return nil }
        let context = Self.commentContext(item: item, ticket: ticket, ticketUrl: ticketUrl, dateText: dateText)
        return MustacheRenderer.render(template, context)
    }
}
