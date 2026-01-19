import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

struct SnipeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snipe",
        abstract: "Query Snipe-IT asset management",
        subcommands: [
            AssetsSubcommand.self,
            AssetSubcommand.self,
            UsersSubcommand.self,
            LocationsSubcommand.self,
            SearchSubcommand.self,
            CheckoutSubcommand.self,
            CheckinSubcommand.self,
            AuditSubcommand.self
        ],
        defaultSubcommand: AssetsSubcommand.self
    )
}

// MARK: - List Assets

struct AssetsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assets",
        abstract: "List assets in Snipe-IT"
    )
    
    @Option(name: .shortAndLong, help: "Filter by status ID")
    var status: Int?
    
    @Option(name: .shortAndLong, help: "Filter by location ID")
    var location: Int?
    
    @Option(name: .shortAndLong, help: "Maximum results")
    var limit: Int = 50
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
        
        guard service.isConfigured else {
            print("Snipe-IT not configured. Set SNIPE_URL and SNIPE_API_KEY.".red)
            throw ExitCode.failure
        }
        
        var assets = try await service.getAssets(statusId: status, locationId: location)
        
        if assets.count > limit {
            assets = Array(assets.prefix(limit))
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(assets)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printAssetsTable(assets)
        }
    }
    
    private func printAssetsTable(_ assets: [SnipeAsset]) {
        print("\n" + "Snipe-IT Assets".bold + " (\(assets.count) shown)\n")
        
        let header = String(format: "%-12s %-15s %-25s %-15s %-15s",
            "Asset Tag", "Serial", "Name", "Status", "Location")
        print(header.underline)
        
        for asset in assets {
            let statusName = asset.statusLabel?.name ?? "Unknown"
            let statusColor: String
            switch asset.statusLabel?.statusMeta {
            case "deployed": statusColor = statusName.green
            case "deployable": statusColor = statusName.cyan
            case "archived": statusColor = statusName.lightBlack
            case "pending": statusColor = statusName.yellow
            default: statusColor = statusName
            }
            
            let row = String(format: "%-12s %-15s %-25s %-15s %-15s",
                String((asset.assetTag ?? "-").prefix(10)),
                String((asset.serial ?? "-").prefix(13)),
                String((asset.name ?? "-").prefix(23)),
                statusColor,
                String((asset.location?.name ?? "-").prefix(13)))
            print(row)
        }
        print("")
    }
}

// MARK: - Single Asset

struct AssetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "asset",
        abstract: "Get details for a specific asset"
    )
    
    @Argument(help: "Asset tag or serial number")
    var identifier: String
    
    @Flag(name: .shortAndLong, help: "Search by serial instead of asset tag")
    var serial: Bool = false
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
        
        guard service.isConfigured else {
            print("Snipe-IT not configured.".red)
            throw ExitCode.failure
        }
        
        let asset: SnipeAsset?
        if serial {
            asset = try await service.getAssetBySerial(identifier)
        } else {
            asset = try await service.getAssetByTag(identifier)
        }
        
        guard let asset = asset else {
            print("Asset not found: \(identifier)".red)
            throw ExitCode.failure
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(asset)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printAssetDetails(asset)
        }
    }
    
    private func printAssetDetails(_ asset: SnipeAsset) {
        print("\n" + "Asset: \(asset.name ?? asset.assetTag ?? "Unknown")".bold.green + "\n")
        print("  Asset Tag:".lightBlue + "    \(asset.assetTag ?? "-")")
        print("  Serial:".lightBlue + "       \(asset.serial ?? "-")")
        print("  Name:".lightBlue + "         \(asset.name ?? "-")")
        print("  Model:".lightBlue + "        \(asset.model?.name ?? "-")")
        print("  Category:".lightBlue + "     \(asset.category?.name ?? "-")")
        print("  Manufacturer:".lightBlue + " \(asset.manufacturer?.name ?? "-")")
        print("  Status:".lightBlue + "       \(asset.statusLabel?.name ?? "-")")
        print("  Location:".lightBlue + "     \(asset.location?.name ?? "-")")
        
        if let assigned = asset.assignedTo {
            print("  Assigned To:".lightBlue + "  \(assigned.name ?? assigned.username ?? "-")")
        }
        
        print("  Last Checkout:".lightBlue + " \(asset.lastCheckout?.formatted ?? "-")")
        print("  Last Audit:".lightBlue + "    \(asset.lastAuditDate ?? "-")")
        print("  Notes:".lightBlue + "        \(asset.notes ?? "-")")
        print("")
    }
}

// MARK: - Users

struct UsersSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "users",
        abstract: "List users in Snipe-IT"
    )
    
    @Option(name: .shortAndLong, help: "Search filter")
    var search: String?
    
    @Option(name: .shortAndLong, help: "Maximum results")
    var limit: Int = 50
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
        
        guard service.isConfigured else {
            print("Snipe-IT not configured.".red)
            throw ExitCode.failure
        }
        
        var users = try await service.getUsers(search: search)
        
        if users.count > limit {
            users = Array(users.prefix(limit))
        }
        
        print("\n" + "Snipe-IT Users".bold + " (\(users.count) shown)\n")
        
        let header = String(format: "%-8s %-20s %-25s %-20s %-5s",
            "ID", "Username", "Name", "Email", "Assets")
        print(header.underline)
        
        for user in users {
            let row = String(format: "%-8d %-20s %-25s %-20s %-5d",
                user.id,
                String((user.username ?? "-").prefix(18)),
                String(user.fullName.prefix(23)),
                String((user.email ?? "-").prefix(18)),
                user.assetsCount ?? 0)
            print(row)
        }
        print("")
    }
}

// MARK: - Locations

struct LocationsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "locations",
        abstract: "List locations in Snipe-IT"
    )
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
        
        guard service.isConfigured else {
            print("Snipe-IT not configured.".red)
            throw ExitCode.failure
        }
        
        let locations = try await service.getLocations()
        
        print("\n" + "Snipe-IT Locations".bold + " (\(locations.count) total)\n")
        
        let header = String(format: "%-8s %-30s %-20s %-8s",
            "ID", "Name", "City", "Assets")
        print(header.underline)
        
        for location in locations {
            let row = String(format: "%-8d %-30s %-20s %-8d",
                location.id,
                String((location.name ?? "-").prefix(28)),
                String((location.city ?? "-").prefix(18)),
                location.assetsCount ?? 0)
            print(row)
        }
        print("")
    }
}

// MARK: - Search

struct SearchSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search assets by any field"
    )
    
    @Argument(help: "Search query")
    var query: String
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
        
        guard service.isConfigured else {
            print("Snipe-IT not configured.".red)
            throw ExitCode.failure
        }
        
        let assets = try await service.getAssets(search: query)
        
        if assets.isEmpty {
            print("\nNo assets found matching: \(query)".yellow + "\n")
            return
        }
        
        print("\n" + "Search Results for '\(query)'".bold + " (\(assets.count) found)\n")
        
        for asset in assets.prefix(20) {
            print("[\(asset.assetTag ?? "-")]".cyan + " " + (asset.name ?? "Unnamed").bold)
            print("  Serial: \(asset.serial ?? "-"), Model: \(asset.model?.name ?? "-")")
            print("  Status: \(asset.statusLabel?.name ?? "-"), Location: \(asset.location?.name ?? "-")")
            print("")
        }
    }
}

// MARK: - Checkout

struct CheckoutSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkout",
        abstract: "Check out an asset to a user"
    )
    
    @Argument(help: "Asset ID")
    var assetId: Int
    
    @Option(name: .shortAndLong, help: "User ID to assign to")
    var user: Int?
    
    @Option(name: .shortAndLong, help: "Location ID to assign to")
    var location: Int?
    
    @Option(name: .shortAndLong, help: "Note for checkout")
    var note: String?
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
        
        guard service.isConfigured else {
            print("Snipe-IT not configured.".red)
            throw ExitCode.failure
        }
        
        guard user != nil || location != nil else {
            print("Must specify either --user or --location".red)
            throw ExitCode.failure
        }
        
        let request = SnipeCheckoutRequest(
            assignedUser: user,
            assignedLocation: location,
            note: note
        )
        
        let response = try await service.checkoutAsset(assetId: assetId, request: request)
        
        if response.status == "success" {
            print("\n" + "Asset checked out successfully!".green + "\n")
        } else {
            print("\n" + "Checkout failed: \(response.messages ?? "Unknown error")".red + "\n")
            throw ExitCode.failure
        }
    }
}

// MARK: - Checkin

struct CheckinSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkin",
        abstract: "Check in an asset"
    )
    
    @Argument(help: "Asset ID")
    var assetId: Int
    
    @Option(name: .shortAndLong, help: "Note for checkin")
    var note: String?
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
        
        guard service.isConfigured else {
            print("Snipe-IT not configured.".red)
            throw ExitCode.failure
        }
        
        let request = SnipeCheckinRequest(note: note)
        let response = try await service.checkinAsset(assetId: assetId, request: request)
        
        if response.status == "success" {
            print("\n" + "Asset checked in successfully!".green + "\n")
        } else {
            print("\n" + "Checkin failed: \(response.messages ?? "Unknown error")".red + "\n")
            throw ExitCode.failure
        }
    }
}

// MARK: - Audit

struct AuditSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Mark an asset as audited"
    )
    
    @Argument(help: "Asset ID")
    var assetId: Int
    
    @Option(name: .shortAndLong, help: "Note for audit")
    var note: String?
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
        
        guard service.isConfigured else {
            print("Snipe-IT not configured.".red)
            throw ExitCode.failure
        }
        
        let request = SnipeAuditRequest(note: note)
        let response = try await service.auditAsset(assetId: assetId, request: request)
        
        if response.status == "success" {
            print("\n" + "Asset audited successfully!".green + "\n")
        } else {
            print("\n" + "Audit failed: \(response.messages ?? "Unknown error")".red + "\n")
            throw ExitCode.failure
        }
    }
}
