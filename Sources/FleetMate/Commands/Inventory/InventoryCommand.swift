import ArgumentParser
import FleetMateCore
import Foundation

/// Backend-neutral inventory operations: the same names reach Snipe-IT today
/// and Cellarum after the switch, chosen by `inventory_backend`.
struct InventoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inventory",
        abstract: "Inventory operations on the configured backend (Snipe-IT or Cellarum)",
        discussion: InventoryArguments.help()
    )

    @OptionGroup var arguments: InventoryArguments

    func run() async throws {
        try await arguments.run()
    }
}

struct InventoryArguments: ParsableArguments {
    @Argument(help: "Group and operation, for example 'buyouts transition', 'files upload', 'operations', 'backend' or 'api'")
    var operation: [String] = []

    @Option(help: "Primary record ID (asset ID, buyout ID, order ID, tag or serial for find-tag/find-serial)")
    var id: String?

    @Option(help: "Nested record ID, such as an invoice, file or order line")
    var resource: String?

    @Option(help: "Record kind for files: asset, person, license, model, supplier, contract, purchase-order, lease-schedule, maintenance, location")
    var record: String?

    @Option(help: "JSON request body")
    var body: String?

    @Option(help: "Path to a file containing the JSON request body")
    var bodyFile: String?

    @Option(help: "Add a query parameter as NAME=VALUE (repeatable)")
    var query: [String] = []

    @Option(help: "File to attach (files upload)")
    var file: String?

    @Option(help: "Note stored with an uploaded file")
    var notes: String?

    @Option(help: "Cellarum domain holding an uploaded file (files upload on Cellarum)")
    var domain: String?

    @Option(help: "Use this backend for one call instead of the configured one: snipe or cellarum")
    var backend: String?

    @Option(help: "Path relative to /api/v1 (for the api operation)")
    var apiPath: String?

    @Option(help: "HTTP method for the api operation")
    var method: String = "GET"

    @Flag(help: "Print the response JSON without reformatting")
    var json = false

    @Option(help: "Write the response to a file, for example a PDF or a downloaded attachment")
    var outputFile: String?

    struct Route {
        let group: String
        let name: String
        let snipe: (method: String, path: String)?
        let cellarum: (method: String, path: String)?

        func route(for backend: InventoryBackend) -> (method: String, path: String)? {
            backend == .snipe ? snipe : cellarum
        }
    }

    static let routes: [Route] = inventoryOperationCatalog.split(separator: "\n").compactMap { row in
        let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4 else { return nil }
        func parse(_ value: String) -> (String, String)? {
            guard value != "-", let space = value.firstIndex(of: " ") else { return nil }
            return (String(value[..<space]), String(value[value.index(after: space)...]))
        }
        return Route(group: fields[0], name: fields[1], snipe: parse(fields[2]), cellarum: parse(fields[3]))
    }

    static func help() -> String {
        var lines = ["Operations (S = Snipe-IT, C = Cellarum):"]
        var lastGroup = ""
        for route in routes {
            if route.group != lastGroup {
                lines.append("  \(route.group)")
                lastGroup = route.group
            }
            let marks = (route.snipe != nil ? "S" : " ") + (route.cellarum != nil ? "C" : " ")
            lines.append("    [\(marks)] \(route.name)")
        }
        lines.append("  files")
        lines.append("    [SC] upload")
        lines.append("")
        lines.append("Also: backend (which system is active), operations [--json] (routes on the active backend),")
        lines.append("and api --method M --api-path P for any endpoint outside the named operations.")
        lines.append("Set inventory_backend: cellarum to move every operation to Cellarum.")
        return lines.joined(separator: "\n")
    }

    func run() async throws {
        let config = try FleetMateConfig.load()
        let selected = try backend.map { name -> InventoryBackend in
            guard let value = InventoryBackend(rawValue: name.lowercased()) else {
                throw ValidationError("--backend is snipe or cellarum.")
            }
            return value
        } ?? InventoryBackend.configured(config)

        let words = operation
        guard let group = words.first else {
            print(Self.help())
            return
        }
        let name = words.dropFirst().joined(separator: " ")

        switch (group, name) {
        case ("backend", ""):
            try printBackend(selected, config: config)
            return
        case ("operations", ""):
            try printOperations(selected)
            return
        default:
            break
        }

        if group == "files", name == "upload" {
            try await upload(try InventoryApi(config: config, backend: selected))
            return
        }

        let method: String
        let template: String
        if group == "api", name.isEmpty {
            let path = try required(apiPath, "--api-path")
            let relative = path.hasPrefix("/api/v1/") ? String(path.dropFirst("/api/v1/".count))
                : (path.hasPrefix("/") ? String(path.dropFirst()) : path)
            guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(self.method.uppercased()) else {
                throw ValidationError("--method is GET, POST, PUT, PATCH or DELETE.")
            }
            (method, template) = (self.method.uppercased(), relative)
        } else {
            guard let known = Self.routes.first(where: { $0.group == group && $0.name == name }) else {
                throw ValidationError("Unknown operation '\(group) \(name)'. See fleetmate inventory --help.")
            }
            guard let route = known.route(for: selected) else {
                throw ValidationError("\(selected.displayName) has no '\(group) \(name)'. Use the api operation, or see fleetmate inventory operations.")
            }
            (method, template) = route
        }

        let api = try InventoryApi(config: config, backend: selected)
        let path = try fill(template, backend: selected)
        let payload = try requestBody()
        if payload != nil, method == "GET" {
            throw ValidationError("A GET takes no body; use --query.")
        }
        let response = try await api.send(method, path: path, query: try queryItems(), body: payload)
        try printResponse(response)
    }

    // MARK: - Pieces

    private func fill(_ template: String, backend: InventoryBackend) throws -> String {
        var path = template
        if path.contains("{record}") {
            path = path.replacingOccurrences(of: "{record}", with: try recordName(for: backend))
        }
        if path.contains("{id}") {
            path = path.replacingOccurrences(of: "{id}", with: InventoryApi.escape(try required(id, "--id")))
        }
        if path.contains("{resource}") {
            path = path.replacingOccurrences(of: "{resource}", with: InventoryApi.escape(try required(resource, "--resource")))
        }
        return path
    }

    private func recordName(for backend: InventoryBackend) throws -> String {
        let kind = try required(record, "--record")
        guard let names = inventoryRecordKinds[kind] else {
            throw ValidationError("--record is one of: \(inventoryRecordKinds.keys.sorted().joined(separator: ", ")).")
        }
        let value = backend == .snipe ? names.snipe : names.cellarum
        guard value != "-" else {
            throw ValidationError("\(backend.displayName) keeps no files on a \(kind).")
        }
        return value
    }

    private func queryItems() throws -> [URLQueryItem] {
        try query.map { item in
            guard let index = item.firstIndex(of: "="), index != item.startIndex else {
                throw ValidationError("Query parameters use NAME=VALUE.")
            }
            return URLQueryItem(name: String(item[..<index]), value: String(item[item.index(after: index)...]))
        }
    }

    private func requestBody() throws -> Data? {
        if body != nil && bodyFile != nil {
            throw ValidationError("Use either --body or --body-file.")
        }
        let source: Data?
        if let body {
            source = Data(body.utf8)
        } else if let bodyFile {
            source = try Data(contentsOf: URL(fileURLWithPath: NSString(string: bodyFile).expandingTildeInPath))
        } else {
            source = nil
        }
        if let source {
            do {
                _ = try JSONSerialization.jsonObject(with: source, options: .fragmentsAllowed)
            } catch {
                throw ValidationError("The request body is not valid JSON.")
            }
        }
        return source
    }

    private func upload(_ api: InventoryApi) async throws {
        let path = NSString(string: try required(file, "--file")).expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ValidationError("Cannot read \(path).")
        }
        let kind = try required(record, "--record")
        guard let names = inventoryRecordKinds[kind] else {
            throw ValidationError("--record is one of: \(inventoryRecordKinds.keys.sorted().joined(separator: ", ")).")
        }
        if api.backend == .cellarum {
            guard names.cellarum != "-" else { throw ValidationError("Cellarum keeps no files on a \(kind).") }
            if domain == nil && !["model", "supplier", "person"].contains(kind) {
                throw ValidationError("Cellarum needs --domain for a file on a \(kind).")
            }
        }
        let response = try await api.upload(
            file: URL(fileURLWithPath: path), snipeRecord: names.snipe, cellarumRecord: names.cellarum,
            id: try required(id, "--id"), notes: notes, domain: domain
        )
        try printResponse(response)
    }

    private func printResponse(_ response: InventoryApi.Response) throws {
        if let outputFile {
            let url = URL(fileURLWithPath: NSString(string: outputFile).expandingTildeInPath)
            try response.data.write(to: url, options: .atomic)
            if !json { print("Wrote \(response.data.count) bytes to \(url.path)") }
            return
        }
        let type = (response.contentType ?? "").lowercased()
        let textual = type.isEmpty || type.contains("json") || type.hasPrefix("text/")
        guard textual else {
            throw ValidationError("The response is \(type); pass --output-file to save it.")
        }
        if response.data.isEmpty {
            print("null")
        } else if !json, let object = try? JSONSerialization.jsonObject(with: response.data, options: .fragmentsAllowed),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
            print(String(decoding: pretty, as: UTF8.self))
        } else {
            print(String(decoding: response.data, as: UTF8.self))
        }
    }

    private func printBackend(_ backend: InventoryBackend, config: FleetMateConfig) throws {
        let url = backend == .snipe ? config.snipeUrl : config.cellarumUrl
        let audience = backend == .snipe ? config.snipeOidcAudience : config.cellarumOidcAudience
        let key = backend == .snipe ? config.snipeApiKey : config.cellarumApiKey
        let auth = (audience ?? "").isEmpty == false ? "entra" : ((key ?? "").isEmpty == false ? "api-key" : "none")
        if json {
            let object: [String: Any] = ["backend": backend.rawValue, "url": url ?? NSNull(), "auth": auth]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("\(backend.displayName) · \(url ?? "no URL configured") · auth: \(auth)")
        }
    }

    private func printOperations(_ backend: InventoryBackend) throws {
        let available = Self.routes.compactMap { route -> (Route, (method: String, path: String))? in
            route.route(for: backend).map { (route, $0) }
        }
        if json {
            let rows: [[String: String]] = available.map { route, target in
                ["group": route.group, "operation": route.name, "method": target.method, "path": target.path]
            } + [["group": "files", "operation": "upload", "method": "POST",
                  "path": backend == .snipe ? "{record}/{id}/files" : "attachments"]]
            let data = try JSONSerialization.data(withJSONObject: ["backend": backend.rawValue, "operations": rows],
                                                  options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("\(backend.displayName) operations:")
            for (route, target) in available {
                print("  \(route.group) \(route.name)".padding(toLength: 40, withPad: " ", startingAt: 0) + "\(target.method) \(target.path)")
            }
        }
    }

    private func required(_ value: String?, _ option: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("\(option) is required.")
        }
        return value
    }
}
