import ArgumentParser
import Foundation
import FleetMateCore
import Rainbow

// The Snipe-IT list commands FleetMate for Windows ships (`fleetmate snipe
// models|categories|licenses|manufacturers|statuses|accessories|consumables|
// components|activity|user`), with the same names, columns and --json switch.

private func snipeService() throws -> SnipeService {
    let service = SnipeService(config: try FleetMateConfig.load())
    guard service.isConfigured else {
        print("Snipe-IT not configured. Set SNIPE_URL and SNIPE_API_KEY.".red)
        throw ExitCode.failure
    }
    return service
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(value), encoding: .utf8) ?? "[]")
}

private func printRawJSON(_ rows: [[String: Any]]) throws {
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

/// A table of columns, each a header, a width and a cell for a row.
private func printTable<Row>(_ title: String, _ rows: [Row], _ columns: [(String, Int, (Row) -> String)]) {
    print("\n" + title.bold + " (\(rows.count) total)\n")
    print(columns.map { $0.0.col($0.1) }.joined(separator: " ").underline)
    for row in rows {
        print(columns.map { $0.2(row).col($0.1) }.joined(separator: " "))
    }
    print("")
}

private extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String {
        switch self[key] {
        case let s as String: return s.isEmpty ? "-" : s
        case let n as NSNumber: return n.stringValue
        default: return "-"
        }
    }
    /// The `name` of a nested reference such as `category`.
    func refName(_ key: String) -> String {
        (self[key] as? [String: Any])?.text("name") ?? "-"
    }
    /// A Snipe-IT date object's formatted value.
    func date(_ key: String) -> String {
        guard let d = self[key] as? [String: Any] else { return "-" }
        let formatted = d.text("formatted")
        return formatted == "-" ? d.text("date") : formatted
    }
}

private func filtered<T>(_ items: [T], _ search: String?, _ name: (T) -> String?) -> [T] {
    guard let search, !search.isEmpty else { return items }
    return items.filter { name($0)?.localizedCaseInsensitiveContains(search) ?? false }
}

// MARK: - Typed lists

struct SnipeUserSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "user", abstract: "Get details for a specific user")

    @Argument(help: "User ID") var id: Int
    @Flag(name: .shortAndLong, help: "Show user's assigned assets") var assets = false
    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let service = try snipeService()
        guard let user = try await service.getUser(id: id) else {
            print("No user found with ID: ".yellow + "\(id)")
            return
        }
        if json { try printJSON(user); return }

        let name = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
        let rows: [(String, String)] = [
            ("ID", String(user.id)),
            ("Username", user.username ?? "-"),
            ("Name", name.isEmpty ? "-" : name),
            ("Email", user.email ?? "-"),
            ("Employee #", user.employeeNum ?? "-"),
            ("Department", user.department?.name ?? "-"),
            ("Manager", user.manager?.name ?? "-"),
            ("Location", user.location?.name ?? "-"),
            ("Assets", String(user.assetsCount ?? 0)),
            ("Licenses", String(user.licensesCount ?? 0)),
            ("Accessories", String(user.accessoriesCount ?? 0)),
            ("Activated", user.activated == true ? "Yes".green : "No".yellow),
        ]
        print("")
        for (key, value) in rows { print(key.col(14).lightBlue + " " + value) }
        print("")

        guard assets else { return }
        let assigned = try await service.getAllAssets().filter { $0.assignedTo?.id == user.id && $0.assignedTo?.type == "user" }
        if assigned.isEmpty {
            print("No assets assigned to this user".dim)
            return
        }
        printTable("Assigned Assets", assigned, [
            ("ID", 8, { String($0.id) }),
            ("Asset Tag", 15, { $0.assetTag ?? "" }),
            ("Name", 30, { $0.name ?? "" }),
            ("Model", 30, { $0.model?.name ?? "-" }),
        ])
    }
}

struct SnipeModelsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "models", abstract: "List asset models")

    @Option(name: .shortAndLong, help: "Filter by name") var search: String?
    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let models = filtered(try await snipeService().getModels(), search) { $0.name }
        if json { try printJSON(models); return }
        printTable("Snipe-IT Models", models, [
            ("ID", 8, { String($0.id) }),
            ("Name", 34, { $0.name ?? "-" }),
            ("Model #", 18, { $0.modelNumber ?? "-" }),
            ("Manufacturer", 18, { $0.manufacturer?.name ?? "-" }),
            ("Category", 18, { $0.category?.name ?? "-" }),
            ("Assets", 8, { String($0.assetsCount ?? 0) }),
        ])
    }
}

struct SnipeCategoriesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "categories", abstract: "List categories")

    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let categories = try await snipeService().getCategories()
        if json { try printJSON(categories); return }
        printTable("Snipe-IT Categories", categories, [
            ("ID", 8, { String($0.id) }),
            ("Name", 30, { $0.name ?? "-" }),
            ("Type", 14, { $0.categoryType ?? "-" }),
            ("Items", 8, { String($0.itemCount ?? $0.assetsCount ?? 0) }),
        ])
    }
}

struct SnipeStatusesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "statuses", abstract: "List status labels")

    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let statuses = try await snipeService().getStatusLabels()
        if json { try printJSON(statuses); return }
        printTable("Snipe-IT Status Labels", statuses, [
            ("ID", 8, { String($0.id) }),
            ("Name", 30, { $0.name ?? "-" }),
            ("Type", 14, { $0.statusType ?? "-" }),
            ("Assets", 8, { String($0.assetsCount ?? 0) }),
        ])
    }
}

struct SnipeActivitySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "activity", abstract: "Show recent activity/audit log")

    @Option(name: [.customShort("n"), .long], help: "Number of entries") var limit = 25
    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let entries = try await snipeService().getActivityLog(limit: limit)
        if json { try printJSON(entries); return }
        printTable("Snipe-IT Activity", entries, [
            ("When", 20, { $0.createdAt?.formatted ?? $0.createdAt?.datetime ?? "-" }),
            ("Action", 14, { $0.actionType ?? "-" }),
            ("Item", 28, { $0.item?.name ?? "-" }),
            ("Target", 24, { $0.target?.name ?? "-" }),
            ("User", 20, { $0.admin?.name ?? "-" }),
        ])
    }
}

// MARK: - Untyped lists

struct SnipeLicensesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "licenses", abstract: "List software licenses")

    @Option(name: .shortAndLong, help: "Search query") var search: String?
    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let rows = try await snipeService().getRawList(.licenses, search: search)
        if json { try printRawJSON(rows); return }
        printTable("Snipe-IT Licenses", rows, [
            ("ID", 8, { $0.text("id") }),
            ("Name", 30, { $0.text("name") }),
            ("Product Key", 24, { $0.text("product_key") }),
            ("Seats", 7, { $0.text("seats") }),
            ("Free", 7, { $0.text("free_seats_count") }),
            ("Expires", 14, { $0.date("expiration_date") }),
        ])
    }
}

struct SnipeManufacturersSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "manufacturers", abstract: "List manufacturers")

    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let rows = try await snipeService().getRawList(.manufacturers)
        if json { try printRawJSON(rows); return }
        printTable("Snipe-IT Manufacturers", rows, [
            ("ID", 8, { $0.text("id") }),
            ("Name", 30, { $0.text("name") }),
            ("Assets", 8, { $0.text("assets_count") }),
        ])
    }
}

/// Accessories, consumables and components share one shape.
private func stockTable(_ title: String, _ rows: [[String: Any]]) {
    printTable(title, rows, [
        ("ID", 8, { $0.text("id") }),
        ("Name", 30, { $0.text("name") }),
        ("Category", 20, { $0.refName("category") }),
        ("Qty", 6, { $0.text("qty") }),
        ("Remaining", 10, { $0.text("remaining") == "-" ? $0.text("remaining_qty") : $0.text("remaining") }),
    ])
}

struct SnipeAccessoriesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "accessories", abstract: "List accessories")

    @Option(name: .shortAndLong, help: "Search query") var search: String?
    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let rows = try await snipeService().getRawList(.accessories, search: search)
        if json { try printRawJSON(rows) } else { stockTable("Snipe-IT Accessories", rows) }
    }
}

struct SnipeConsumablesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "consumables", abstract: "List consumables")

    @Option(name: .shortAndLong, help: "Search query") var search: String?
    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let rows = try await snipeService().getRawList(.consumables, search: search)
        if json { try printRawJSON(rows) } else { stockTable("Snipe-IT Consumables", rows) }
    }
}

struct SnipeComponentsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "components", abstract: "List components")

    @Option(name: .shortAndLong, help: "Search query") var search: String?
    @Flag(name: .shortAndLong, help: "Output as JSON") var json = false

    func run() async throws {
        let rows = try await snipeService().getRawList(.components, search: search)
        if json { try printRawJSON(rows) } else { stockTable("Snipe-IT Components", rows) }
    }
}
