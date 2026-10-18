import Foundation

/// A git checkout found on disk.
public struct DiscoveredCheckout: Codable, Sendable, Hashable {
    public let path: String
    public let remoteUrl: String?
    public let key: RepoKey?
    /// Found only because a VS Code workspace file names it. Such a clone is
    /// offered for the person to tick, never tracked on its own.
    public let fromWorkspace: Bool
    /// Keys in the clone's own config that make git run a program
    /// (`core.fsmonitor`, `filter.lfs.process`, …). Such a clone is flagged
    /// and starts unselected wherever it is offered.
    public let commandConfig: [String]

    /// The clone's settings can run commands.
    public var runsCommands: Bool { !commandConfig.isEmpty }

    public init(path: String, remoteUrl: String?, key: RepoKey?, fromWorkspace: Bool = false, commandConfig: [String] = []) {
        self.path = path
        self.remoteUrl = remoteUrl
        self.key = key
        self.fromWorkspace = fromWorkspace
        self.commandConfig = commandConfig
    }

    enum CodingKeys: String, CodingKey { case path, remoteUrl, key, fromWorkspace, commandConfig }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        remoteUrl = try c.decodeIfPresent(String.self, forKey: .remoteUrl)
        key = try c.decodeIfPresent(RepoKey.self, forKey: .key)
        fromWorkspace = try c.decodeIfPresent(Bool.self, forKey: .fromWorkspace) ?? false
        commandConfig = try c.decodeIfPresent([String].self, forKey: .commandConfig) ?? []
    }
}

/// Walks scan roots for git checkouts.
///
/// A folder is a checkout when it holds `.git` (a directory, or a file for a
/// submodule). The walk stops descending at a checkout, skips hidden folders,
/// the built-in skip list (`node_modules`, `.build`, `bin`, `obj`, …) and the
/// configured one, and never goes deeper than `maxDepth` levels below a root.
/// A skipped name is still reported when the folder is itself a checkout, so
/// a repository called `build` is found; its contents are never walked.
/// Linked worktrees are not reported: they belong to the checkout they were
/// added from.
///
/// VS Code multi-root workspaces (`*.code-workspace`) sitting directly in a
/// scan root or the home folder contribute the checkouts their `folders`
/// name, but only folders inside a scan root. A workspace file inside a
/// clone is never read: whoever wrote the repository wrote it too.
///
/// Nothing here runs git. A clone found on disk is untrusted until the
/// person adds it, and its own config (`core.fsmonitor`, hooks) could run
/// code, so the origin is read from `.git/config` as text.
public enum RepoDiscovery {

    /// Folder names never descended into, whatever the settings say: build
    /// output, package caches and worktree folders hold no checkouts of
    /// their own, and walking them is what makes a scan slow.
    public static let builtInSkip: [String] = [
        ".worktrees", "node_modules", ".build", "build", "bin", "obj", "dist", "target",
        "DerivedData", "Pods", "Carthage", "vendor", "packages", "__pycache__", "venv",
    ]

    /// Where people commonly keep clones, relative to the home folder. On a
    /// first run these are looked in and whatever they hold is proposed.
    public static let commonLocations: [String] = [
        "~/Developer", "~/DevOps", "~/Projects", "~/src", "~/code", "~/git",
        "~/repos", "~/GitHub", "~/Documents/GitHub", "~/source/repos",
    ]

    /// The common locations that exist on this machine, as stored (`~/…`).
    public static func existingCommonLocations() -> [String] {
        commonLocations.filter { location in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: RepoSettings.expand(location), isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// What one walk found.
    public struct ScanResult: Sendable, Equatable {
        /// Checkouts the walk found, in walk order, each once.
        public var checkouts: [String]
        /// Further checkouts named only by a workspace file; proposals.
        public var workspaceCheckouts: [String]
        /// `.code-workspace` files that were read.
        public var workspaceFiles: [String]
    }

    /// Paths of checkouts under `roots`, found without spawning a process.
    public static func findCheckouts(roots: [String], maxDepth: Int, skip: [String]) -> [String] {
        scan(roots: roots, maxDepth: maxDepth, skip: skip).checkouts
    }

    /// Walks `roots` for checkouts and VS Code workspace files.
    public static func scan(roots: [String], maxDepth: Int, skip: [String]) -> ScanResult {
        let fm = FileManager.default
        let skipSet = Set((skip + builtInSkip).map { $0.lowercased() })
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var found: [String] = []
        var seen = Set<String>()
        var workspaceFiles: [String] = []
        var resolvedRoots: [String] = []

        func note(_ path: String) {
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(standard).inserted { found.append(path) }
        }

        /// Workspace files directly in `directory`, which is a root or home.
        func collectWorkspaces(in directory: String) {
            guard !isCheckout(directory), let children = try? fm.contentsOfDirectory(atPath: directory) else { return }
            for child in children.sorted() where child.lowercased().hasSuffix(".code-workspace") {
                let file = (directory as NSString).appendingPathComponent(child)
                if (try? fm.destinationOfSymbolicLink(atPath: file)) != nil { continue }
                workspaceFiles.append(file)
            }
        }

        func walk(_ directory: String, depth: Int) {
            if isCheckout(directory) {
                note(directory)
                return
            }
            guard depth < maxDepth, let children = try? fm.contentsOfDirectory(atPath: directory) else { return }
            for child in children.sorted() {
                if child.hasPrefix(".") { continue }
                let full = (directory as NSString).appendingPathComponent(child)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                // Do not follow symlinked folders: they lead to loops and duplicates.
                if (try? fm.destinationOfSymbolicLink(atPath: full)) != nil { continue }
                if skipSet.contains(child.lowercased()) || (directory == home && child == "Library") {
                    if isCheckout(full) { note(full) }
                    continue
                }
                walk(full, depth: depth + 1)
            }
        }

        for root in roots {
            var expanded = RepoSettings.expand(root)
            while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            walk(expanded, depth: 0)
            resolvedRoots.append(resolved(expanded))
            collectWorkspaces(in: expanded)
        }
        if !roots.isEmpty, !resolvedRoots.contains(resolved(home)) { collectWorkspaces(in: home) }

        let walked = found.count
        for file in workspaceFiles {
            for folder in workspaceFolders(file) {
                guard let checkout = enclosingCheckout(folder) else { continue }
                // The checkout itself must lie inside a scan root, after
                // symlinks are resolved, on a path-separator boundary.
                guard isInside(resolved(checkout), anyOf: resolvedRoots) else { continue }
                note(checkout)
            }
        }
        return ScanResult(checkouts: Array(found[..<walked]), workspaceCheckouts: Array(found[walked...]), workspaceFiles: workspaceFiles)
    }

    /// `path` with symlinks resolved and `.`/`..` removed.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether `path` is one of `roots` or below one, compared on whole path
    /// components so `/a/bc` is not inside `/a/b`.
    static func isInside(_ path: String, anyOf roots: [String]) -> Bool {
        roots.contains { root in
            let base = root.hasSuffix("/") ? String(root.dropLast()) : root
            return path == base || path.hasPrefix(base + "/")
        }
    }

    /// True for a main checkout or submodule; false for a linked worktree,
    /// whose `.git` file points into another repository's `worktrees/` folder.
    static func isCheckout(_ directory: String) -> Bool {
        let dotGit = (directory as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue { return true }
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return false }
        return !pointer.replacingOccurrences(of: "\\", with: "/").contains("/worktrees/")
    }

    /// The checkout `path` is in: itself, or the nearest parent that is one
    /// (a workspace often opens a subfolder of a repository).
    static func enclosingCheckout(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var current = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        for _ in 0..<8 {
            if isCheckout(current.path) { return current.path }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    /// Absolute paths of the folders a `.code-workspace` file lists. Paths are
    /// relative to the file unless absolute; the file is JSON with comments
    /// and trailing commas allowed, as VS Code writes it. Nothing is
    /// expanded (`~`, variables), and network (`//host/share`, `\\host`),
    /// device (`\\?\`, `\\.\`) and URI (`scheme:`) forms are dropped before
    /// the filesystem is touched.
    public static func workspaceFolders(_ file: String) -> [String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return workspaceFolders(json: text, relativeTo: (file as NSString).deletingLastPathComponent)
    }

    static func workspaceFolders(json text: String, relativeTo base: String) -> [String] {
        guard let data = strippingJSONComments(text).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = object["folders"] as? [[String: Any]] else { return [] }
        return folders.compactMap { folder in
            guard let raw = folder["path"] as? String, isPlainLocalPath(raw) else { return nil }
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL.path }
            return URL(fileURLWithPath: base).appendingPathComponent(raw).standardizedFileURL.path
        }
    }

    /// A relative or absolute local path, and nothing that could reach the
    /// network, a device or another expansion.
    static func isPlainLocalPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\u{0}") else { return false }
        if path.contains("\\") { return false }
        if path.hasPrefix("//") || path.hasPrefix("~") || path.contains("$") || path.contains("%") { return false }
        // A colon before the first slash is a scheme (`vscode-remote:`,
        // `file:`) or a drive letter: neither is a local Mac path.
        if let colon = path.firstIndex(of: ":"), path.firstIndex(of: "/").map({ colon < $0 }) ?? true { return false }
        return true
    }

    /// The `origin` URL from the clone's own config file, read as text so no
    /// git process (and none of the clone's config) runs. Follows a `.git`
    /// file to the real git folder for a submodule.
    public static func readOrigin(checkout: String) -> String? {
        readConfig(checkout: checkout).flatMap { originURL(inConfig: $0) }
    }

    /// The clone's `config` (and `config.worktree`) as text, or nil.
    static func readConfig(checkout: String) -> String? {
        guard let gitDir = gitDirectory(of: checkout) else { return nil }
        let texts = ["config", "config.worktree"].compactMap {
            try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent($0), encoding: .utf8)
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Config keys that make git run a program the config names. Matched on
    /// `section.key` with any subsection, all lowercased as git compares them.
    static func isCommandKey(section: String, subsection: String?, key: String, value: String) -> Bool {
        let boolean: Set<String> = ["", "true", "false", "yes", "no", "on", "off", "0", "1"]
        switch (section, key) {
        case ("core", "fsmonitor"):
            // true and false choose the built-in daemon or nothing; any other
            // value is a program.
            return !boolean.contains(value.lowercased())
        case ("core", "hookspath"), ("core", "sshcommand"), ("core", "pager"), ("core", "editor"),
             ("core", "askpass"), ("core", "gitproxy"), ("sequence", "editor"), ("diff", "external"),
             ("gpg", "program"), ("include", "path"), ("includeif", "path"), ("core", "alternaterefscommand"),
             ("remote", "uploadpack"), ("remote", "receivepack"):
            return true
        case ("credential", "helper"):
            return true
        case ("diff", "textconv"), ("diff", "command"), ("merge", "driver"), ("gpg", _) where key == "program":
            return true
        case ("filter", _):
            return true
        case ("protocol", "allow"):
            return value.lowercased() == "always"
        case ("pager", _):
            return true
        default:
            return false
        }
    }

    /// `section[.subsection].key` names in git config text whose values git
    /// would run as programs, in file order.
    public static func commandConfigKeys(inConfig text: String) -> [String] {
        var section = ""
        var subsection: String?
        var found: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix(";") || line.isEmpty { continue }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let header = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if let quote = header.firstIndex(of: "\"") {
                    section = header[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
                    subsection = header[header.index(after: quote)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                } else if let dot = header.firstIndex(of: ".") {
                    section = header[..<dot].lowercased()
                    subsection = String(header[header.index(after: dot)...])
                } else {
                    section = header.lowercased()
                    subsection = nil
                }
                line = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            }
            let name: String
            let value: String
            if let equals = line.firstIndex(of: "=") {
                name = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else {
                name = line.split(separator: " ").first.map { $0.lowercased() } ?? ""
                value = ""
            }
            guard !name.isEmpty, !section.isEmpty else { continue }
            if isCommandKey(section: section, subsection: subsection, key: name, value: value) {
                let full = ([section] + (subsection.map { [$0] } ?? []) + [name]).joined(separator: ".")
                if !found.contains(full) { found.append(full) }
            }
        }
        return found
    }

    static func gitDirectory(of checkout: String) -> String? {
        let dotGit = (checkout as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = pointer.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard isPlainLocalPath(target) else { return nil }
        return target.hasPrefix("/") ? target : URL(fileURLWithPath: checkout).appendingPathComponent(target).standardizedFileURL.path
    }

    /// `url` under `[remote "origin"]` in git config text.
    static func originURL(inConfig text: String) -> String? {
        var inOrigin = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).replacingOccurrences(of: "\t", with: " ")
                inOrigin = header.lowercased() == "remote \"origin\""
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "url" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// JSONC to JSON: drops `//` and `/* */` comments outside strings and
    /// commas before a closing bracket.
    static func strippingJSONComments(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "]" || chars[j] == "}" { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Finds checkouts and reads each one's origin from its config file. No
    /// git process runs. Workspace-file proposals are included only when
    /// asked for, marked `fromWorkspace`.
    public static func discover(settings: RepoSettings, includeWorkspaceFolders: Bool = false) async -> [DiscoveredCheckout] {
        let result = scan(roots: settings.scanRoots, maxDepth: settings.scanDepth, skip: settings.skipDirectories)
        func checkout(_ path: String, fromWorkspace: Bool) -> DiscoveredCheckout {
            let config = readConfig(checkout: path)
            let origin = config.flatMap { originURL(inConfig: $0) }
            return DiscoveredCheckout(path: path, remoteUrl: origin, key: origin.flatMap(RepoRemoteURL.parse),
                                      fromWorkspace: fromWorkspace, commandConfig: config.map(commandConfigKeys(inConfig:)) ?? [])
        }
        var found = result.checkouts.map { checkout($0, fromWorkspace: false) }
        if includeWorkspaceFolders { found += result.workspaceCheckouts.map { checkout($0, fromWorkspace: true) } }
        return found
    }
}

/// Maps `items` through `transform` with at most `limit` running at once,
/// preserving order.
public func boundedMap<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int,
    _ transform: @escaping @Sendable (T) async -> R
) async -> [R] {
    guard !items.isEmpty else { return [] }
    let width = max(1, limit)
    return await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(width, items.count) {
            let index = next, item = items[index]
            group.addTask { (index, await transform(item)) }
            next += 1
        }
        while let (index, value) = await group.next() {
            results[index] = value
            if next < items.count {
                let i = next, item = items[i]
                group.addTask { (i, await transform(item)) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}
