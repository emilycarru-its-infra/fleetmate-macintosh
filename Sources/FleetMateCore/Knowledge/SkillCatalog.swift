import Foundation

/// The shared agent setup every repository inherits: skills, git hooks,
/// scoped standards and the shared AGENTS block, read from FleetMate's copy
/// of the hub repository.
public struct SkillCatalog: Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case skill = "Skills"
            case hook = "Hooks"
            case standard = "Standards"
        }
        public let kind: Kind
        public let name: String
        public let summary: String
        /// Path inside the hub repository.
        public let path: String
        /// Files that ship with it — scripts beside a SKILL.md.
        public let files: [String]
        /// Markdown to show; source text for scripts.
        public let body: String
        public var id: String { "\(kind.rawValue):\(path)" }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Read `agents/` from the hub copy at `root`.
    public static func load(hubRoot root: URL) -> SkillCatalog {
        let fm = FileManager.default
        let agents = root.appendingPathComponent("agents")
        var entries: [Entry] = []
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func list(_ url: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

        for name in list(agents.appendingPathComponent("skills")) {
            let dir = agents.appendingPathComponent("skills/\(name)")
            let skillFile = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else { continue }
            let (fields, body) = FrontMatter.split(read(skillFile))
            entries.append(Entry(kind: .skill, name: fields["name"] ?? name,
                                 summary: fields["description"] ?? "",
                                 path: "agents/skills/\(name)/SKILL.md",
                                 files: list(dir).filter { $0 != "SKILL.md" && !$0.hasPrefix(".") },
                                 body: body))
        }
        for name in list(agents.appendingPathComponent("githooks")) where !name.hasPrefix(".") {
            let url = agents.appendingPathComponent("githooks/\(name)")
            let text = read(url)
            let summary = name.hasSuffix(".md") ? FrontMatter.split(text).body.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.isEmpty }.map(String.init) ?? ""
                : Self.leadingComment(text)
            entries.append(Entry(kind: .hook, name: name, summary: summary, path: "agents/githooks/\(name)",
                                 files: [], body: name.hasSuffix(".md") ? text : "```\n\(text)\n```"))
        }
        let shared = agents.appendingPathComponent("AGENTS.shared.md")
        if fm.fileExists(atPath: shared.path) {
            entries.append(Entry(kind: .standard, name: "Estate-wide agent standards",
                                 summary: "The shared AGENTS.md block every repository carries.",
                                 path: "agents/AGENTS.shared.md", files: [], body: read(shared)))
        }
        for name in list(agents.appendingPathComponent("scopes")) where name.hasSuffix(".md") && name != "README.md" {
            let text = read(agents.appendingPathComponent("scopes/\(name)"))
            entries.append(Entry(kind: .standard, name: String(name.dropLast(3)),
                                 summary: "Scoped standard: \(name.dropLast(3))",
                                 path: "agents/scopes/\(name)", files: [], body: text))
        }
        return SkillCatalog(entries: entries)
    }

    /// The first comment block of a script, as its one-line summary.
    static func leadingComment(_ text: String) -> String {
        for line in text.split(separator: "\n").prefix(15) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#!") { continue }
            if t.hasPrefix("#") || t.hasPrefix("\"\"\"") || t.hasPrefix("//") {
                let s = t.trimmingCharacters(in: CharacterSet(charactersIn: "#/\" "))
                if !s.isEmpty { return s }
            }
        }
        return ""
    }
}
