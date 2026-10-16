import Foundation

/// Optional agent-authored sidebar labels. They never execute commands or change the launch.
public struct AgentSessionMetadata: Decodable {
    public let title: String?
    public let section: String?

    private enum CodingKeys: String, CodingKey { case title, section }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title).map(Self.label)
        section = try values.decodeIfPresent(String.self, forKey: .section).map(Self.label)
    }

    private static func label(_ value: String) -> String {
        String(AgentContextSanitizer.clean(value, keepNewlines: false)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }
}
