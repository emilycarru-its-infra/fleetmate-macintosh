import Foundation
import Yams

/// The YAML command library shared by the Manage tab, the CLI and the
/// operator's editor. Shape:
///
///     categories:
///       - name: System
///         commands:
///           - label: Hostname
///             command: hostname
///             trust: safe
///
/// Parsed and written with Yams. A missing `trust` is inferred from the
/// command text and reported by the audit.
public enum CommandLibrary {

    public enum LibraryError: Error, LocalizedError {
        case unreadable(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): "Could not read command library at \(path)"
            case .malformed(let why): "Command library is malformed: \(why)"
            }
        }
    }

    // MARK: - Read

    public static func load(path: String) throws -> [CommandCategory] {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw LibraryError.unreadable(expanded)
        }
        return try parse(content)
    }

    public static func parse(_ yaml: String) throws -> [CommandCategory] {
        let root: Any?
        do {
            root = try Yams.load(yaml: yaml)
        } catch {
            throw LibraryError.malformed(error.localizedDescription)
        }
        guard let dict = root as? [String: Any] else {
            if root == nil { return [] }
            throw LibraryError.malformed("top level is not a mapping")
        }
        guard let rawCategories = dict["categories"] as? [Any] else { return [] }

        var categories: [CommandCategory] = []
        for rawCategory in rawCategories {
            guard let cat = rawCategory as? [String: Any] else { continue }
            let name = Self.string(cat["name"]) ?? ""
            guard !name.isEmpty else { continue }
            var commands: [ManageCommand] = []
            for rawCommand in (cat["commands"] as? [Any]) ?? [] {
                guard let cmd = rawCommand as? [String: Any] else { continue }
                let label = Self.string(cmd["label"]) ?? ""
                guard !label.isEmpty else { continue }
                let command = Self.string(cmd["command"]) ?? ""
                let trust = Self.string(cmd["trust"]).flatMap { CommandTrustLevel(rawValue: $0.lowercased()) }
                commands.append(ManageCommand(label: label, command: command, trustLevel: trust))
            }
            categories.append(CommandCategory(name: name, commands: commands))
        }
        return categories
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as Int: return String(n)
        case let d as Double: return String(d)
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    // MARK: - Write

    /// Emit the library in the shared shape. Every command states its trust,
    /// so a library that passed through the app never has an inferred level
    /// the next reader has to guess at.
    public static func serialize(_ categories: [CommandCategory]) throws -> String {
        // Emitted through the Node API so keys keep their order (name before
        // commands, label before command before trust) instead of being sorted.
        func scalar(_ v: String) -> Node { Node(v) }
        func mapping(_ pairs: [(String, Node)]) -> Node { .mapping(Node.Mapping(pairs.map { (Node($0.0), $0.1) })) }
        func sequence(_ nodes: [Node]) -> Node { .sequence(Node.Sequence(nodes)) }

        let root = mapping([
            ("categories", sequence(categories.map { cat in
                mapping([
                    ("name", scalar(cat.name)),
                    ("commands", sequence(cat.commands.map { cmd in
                        mapping([
                            ("label", scalar(cmd.label)),
                            ("command", scalar(cmd.command)),
                            ("trust", scalar(cmd.trustLevel.rawValue)),
                        ])
                    })),
                ])
            })),
        ])
        return try Yams.serialize(node: root, width: -1)
    }

    public static func save(_ categories: [CommandCategory], to path: String) throws {
        let expanded = NSString(string: path).expandingTildeInPath
        let yaml = try serialize(categories)
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Merge

    /// Add bundled categories and commands the target does not have, matched
    /// by normalized name and label, without touching what the operator
    /// already has. Returns true when anything was added.
    @discardableResult
    public static func mergeMissing(into target: inout [CommandCategory], bundled: [CommandCategory]) -> Bool {
        var changed = false
        for bundledCategory in bundled {
            if let index = target.firstIndex(where: { normalize($0.name) == normalize(bundledCategory.name) }) {
                let existing = Set(target[index].commands.map { normalize($0.label) })
                let missing = bundledCategory.commands.filter { !existing.contains(normalize($0.label)) }
                if !missing.isEmpty {
                    target[index].commands.append(contentsOf: missing)
                    changed = true
                }
            } else {
                target.append(bundledCategory)
                changed = true
            }
        }
        return changed
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Audit

    /// Structural problems and trust that is stated weaker than the command's
    /// text warrants. Errors are things a run would trip over; warnings are
    /// things a reviewer should look at.
    public static func audit(_ categories: [CommandCategory]) -> [CommandAuditIssue] {
        var issues: [CommandAuditIssue] = []
        var seenCategories = Set<String>()
        for cat in categories {
            if !seenCategories.insert(normalize(cat.name)).inserted {
                issues.append(CommandAuditIssue(severity: .error, category: cat.name, message: "duplicate category name"))
            }
            if cat.commands.isEmpty {
                issues.append(CommandAuditIssue(severity: .warning, category: cat.name, message: "category has no commands"))
            }
            var seenLabels = Set<String>()
            for cmd in cat.commands {
                if !seenLabels.insert(normalize(cmd.label)).inserted {
                    issues.append(CommandAuditIssue(severity: .error, category: cat.name, label: cmd.label, message: "duplicate label in category"))
                }
                if cmd.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(CommandAuditIssue(severity: .error, category: cat.name, label: cmd.label, message: "empty command"))
                    continue
                }
                if !cmd.trustWasStated {
                    issues.append(CommandAuditIssue(severity: .warning, category: cat.name, label: cmd.label, message: "trust level not stated (inferred \(cmd.inferredTrust.rawValue))"))
                } else if cmd.trustIsUnderstated {
                    issues.append(CommandAuditIssue(severity: .warning, category: cat.name, label: cmd.label,
                        message: "trust stated as \(cmd.trustLevel.rawValue) but the command reads as \(cmd.inferredTrust.rawValue)"))
                }
                if let template = PlaceholderTemplate.detect(label: cmd.label, command: cmd.command) {
                    for placeholder in template.placeholders where PlaceholderTemplate.isSensitive(placeholder) {
                        if !cmd.command.contains("'\(placeholder)'") && !cmd.command.contains("\"\(placeholder)\"") {
                            issues.append(CommandAuditIssue(severity: .info, category: cat.name, label: cmd.label,
                                message: "\(placeholder) is bare; it will be single-quoted at run time"))
                        }
                    }
                }
            }
        }
        return issues
    }

    // MARK: - Bundled

    /// The library that ships inside FleetMate.
    public static func loadBundled() -> [CommandCategory] {
        (try? parse(BundledCommandLibrary.yaml)) ?? defaultCategories()
    }

    /// The bare minimum when neither the operator's file nor the bundled
    /// library can be read.
    public static func defaultCategories() -> [CommandCategory] {
        [
            CommandCategory(name: "System", commands: [
                ManageCommand(label: "Hostname", command: "hostname", trustLevel: .safe),
                ManageCommand(label: "macOS version", command: "sw_vers", trustLevel: .safe),
                ManageCommand(label: "Uptime", command: "uptime", trustLevel: .safe),
                ManageCommand(label: "Disk usage", command: "df -h / | tail -1", trustLevel: .safe),
            ]),
            CommandCategory(name: "Munki Operations", commands: [
                ManageCommand(label: "Munki check only", command: "sudo /usr/local/munki/managedsoftwareupdate --checkonly", trustLevel: .safe),
                ManageCommand(label: "Munki auto", command: "sudo /usr/local/munki/managedsoftwareupdate --auto", trustLevel: .caution),
            ]),
        ]
    }

    /// Find a command by label across the library, case-insensitively.
    public static func find(label: String, in categories: [CommandCategory]) -> ManageCommand? {
        let wanted = normalize(label)
        for cat in categories {
            if let cmd = cat.commands.first(where: { normalize($0.label) == wanted }) { return cmd }
        }
        return nil
    }
}
