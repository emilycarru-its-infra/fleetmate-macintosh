import Foundation

public enum TeamsThreadCopy {
    public static func message(_ message: TeamsMessage, allowedHosts: [String], markdown: Bool = false) -> String {
        let who = TeamsText.line(message.authorDisplayName ?? "Unknown author")
        let when = TeamsText.localTime(message.createdAt)
        var lines = [markdown ? "**\(escape(who))** · \(escape(when))" : "\(who) · \(when)", ""]
        let body = TeamsText.body(message.text)
        lines.append(markdown ? escape(body) : body)
        for attachment in message.attachments {
            let name = TeamsText.line(attachment.name)
            if let url = TeamsLinkPolicy.safeURL(attachment.url, allowedHosts: allowedHosts) {
                lines.append(markdown ? "[\(escape(name))](<\(url.absoluteString)>)" : "\(name): \(url.absoluteString)")
            } else { lines.append(markdown ? escape(name) : name) }
        }
        if let url = TeamsLinkPolicy.safeURL(message.webUrl, allowedHosts: allowedHosts) {
            lines += ["", markdown ? "[Source](<\(url.absoluteString)>)" : "Source: \(url.absoluteString)"]
        }
        return lines.joined(separator: "\n")
    }

    public static func thread(_ thread: TeamsThread, allowedHosts: [String], markdown: Bool = false) -> String {
        let title = TeamsText.line(thread.subject).isEmpty ? "Teams thread" : TeamsText.line(thread.subject)
        let location = "\(TeamsText.line(thread.teamName)) › \(TeamsText.line(thread.channelName))"
        var lines = [markdown ? "# " + escape(title) : title, markdown ? escape(location) : location]
        if let url = TeamsLinkPolicy.safeURL(thread.webUrl, allowedHosts: allowedHosts) {
            lines.append(markdown ? "[Open in Teams](<\(url.absoluteString)>)" : "Source: \(url.absoluteString)")
        }
        lines.append("")
        lines += thread.messages.map { message($0, allowedHosts: allowedHosts, markdown: markdown) }
        return lines.joined(separator: "\n\n")
    }

    private static func escape(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for symbol in ["\\", "`", "*", "_", "[", "]", "#", "|", "~"] {
            result = result.replacingOccurrences(of: symbol, with: "\\" + symbol)
        }
        return result
    }
}
