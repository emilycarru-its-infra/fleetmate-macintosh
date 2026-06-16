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
        
        let header = "Asset Tag".col(12) + " " + "Serial".col(15) + " " + "Name".col(25) + " " + "Status".col(15) + " " + "Location".col(15)
        print(header.underline)

        for asset in assets {
            let statusName = (asset.statusLabel?.name ?? "Unknown")
            let statusCell = statusName.col(15)
            let statusColor: String
            switch asset.statusLabel?.statusMeta {
            case "deployed": statusColor = statusCell.green
            case "deployable": statusColor = statusCell.cyan
            case "archived": statusColor = statusCell.lightBlack
            case "pending": statusColor = statusCell.yellow
            default: statusColor = statusCell
            }

            let row = (asset.assetTag ?? "-").col(12) + " "
                + (asset.serial ?? "-").col(15) + " "
                + (asset.name ?? "-").col(25) + " "
                + statusColor + " "
                + (asset.location?.name ?? "-").col(15)
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
        print("  Last Audit:".lightBlue + "    \(asset.lastAuditDate?.formatted ?? "-")")
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
        
        let header = "ID".col(8) + " " + "Username".col(20) + " " + "Name".col(25) + " " + "Email".col(20) + " " + "Assets".col(5)
        print(header.underline)

        for user in users {
            let row = user.id.col(8) + " "
                + (user.username ?? "-").col(20) + " "
                + user.fullName.col(25) + " "
                + (user.email ?? "-").col(20) + " "
                + (user.assetsCount ?? 0).col(5)
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
        
        let header = "ID".col(8) + " " + "Name".col(30) + " " + "City".col(20) + " " + "Assets".col(8)
        print(header.underline)

        for location in locations {
            let row = location.id.col(8) + " "
                + (location.name ?? "-").col(30) + " "
                + (location.city ?? "-").col(20) + " "
                + (location.assetsCount ?? 0).col(8)
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
