import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

// `fleetmate tdx assets|asset|from-error`, matching FleetMate for Windows.

private func tdxService() throws -> TdxService {
    let service = TdxService(config: try FleetMateConfig.load())
    guard service.isConfigured else {
        print("TeamDynamix not configured.".red)
        throw ExitCode.failure
    }
    return service
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(value), encoding: .utf8) ?? "{}")
}

struct TdxAssetsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "assets", abstract: "Search assets (partial results)")

    @Option(name: [.customShort("q"), .long], help: "Search text (name, tag, serial, etc.)") var search: String?
    @Option(name: [.customShort("n"), .long], help: "Maximum results") var limit = 25
    @Flag(name: .long, help: "Output as JSON") var json = false

    func run() async throws {
        let assets = try await tdxService().searchAssets(search, maxResults: limit)
        if json { try printJSON(assets); return }
        guard !assets.isEmpty else { print("No assets found".yellow); return }

        print("")
        print(("ID".col(8) + " " + "Tag".col(12) + " " + "Name".col(30) + " " + "Serial".col(20) + " "
               + "Status".col(14) + " " + "Location".col(20)).underline)
        for a in assets {
            print(String(a.id).col(8) + " " + (a.tag ?? "-").col(12) + " " + (a.name ?? "-").col(30) + " "
                  + (a.serialNumber ?? "-").col(20) + " " + (a.status ?? "-").col(14) + " " + (a.location ?? "-").col(20))
        }
        print("\nShowing \(assets.count) assets\n".dim)
    }
}

struct TdxAssetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "asset", abstract: "Get asset details by ID")

    @Argument(help: "Asset ID") var id: Int
    @Flag(name: .long, help: "Output as JSON") var json = false

    func run() async throws {
        guard let asset = try await tdxService().getAsset(id: id) else {
            print("Asset not found".yellow)
            return
        }
        if json { try printJSON(asset); return }
        print("\n" + (asset.name ?? "(no name)").bold + "\n")
        for (label, value) in [
            ("ID", String(asset.id)), ("Tag", asset.tag), ("Serial", asset.serialNumber),
            ("Model", asset.model), ("Manufacturer", asset.manufacturer), ("Type", asset.productType),
            ("Status", asset.status), ("Location", asset.location),
        ] {
            print(label.col(14).dim + " " + (value ?? "-"))
        }
        print("")
    }
}

struct TdxFromErrorSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "from-error", abstract: "Create a ticket from a deployment error")

    @Argument(help: "Device name") var device: String
    @Argument(help: "Software item name with error") var item: String
    @Option(name: [.customShort("t"), .long], help: "Ticket type ID") var type: Int?
    @Option(name: [.customShort("p"), .long], help: "Priority ID") var priority: Int?
    @Flag(name: .long, help: "Output as JSON") var json = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let tdx = try tdxService()
        let reportMate = ReportMateService(config: config)
        guard reportMate.isConfigured else {
            print("ReportMate is not configured".red)
            throw ExitCode.failure
        }

        let installs = try await reportMate.getDeviceInstalls(device)
        guard let failed = installs.first(where: { $0.itemName.caseInsensitiveCompare(item) == .orderedSame && $0.isError }) else {
            print("No error found for \(item) on \(device)".yellow)
            return
        }

        let info = try? await reportMate.findDevice(device)
        let deviceName = info?.displayName ?? (failed.deviceName.isEmpty ? device : failed.deviceName)
        let errorMessage = failed.lastError ?? (failed.currentStatus.isEmpty ? "Unknown error" : failed.currentStatus)
        let lastSeen = info?.lastSeen.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "Unknown"

        let description = """
            ## Deployment Error Report

            **Device:** \(deviceName)
            **Software:** \(item)
            **Status:** \(failed.currentStatus.isEmpty ? "Error" : failed.currentStatus)

            ### Error Message
            \(errorMessage)

            ### Additional Details
            - Serial: \(info?.serialNumber ?? "Unknown")
            - IP Address: \(info?.ipAddress ?? "Unknown")
            - Last Seen: \(lastSeen)

            ---
            *Ticket created by FleetMate CLI*
            """

        let request = CreateTicketRequest(
            typeId: type ?? config.tdxDefaultTypeId ?? 0,
            title: "[FleetMate] \(deviceName): \(item) deployment failure",
            description: description,
            priorityId: priority
        )
        guard let ticket = try await tdx.createTicket(request: request) else {
            print("Failed to create ticket from error".red)
            throw ExitCode.failure
        }

        if json { try printJSON(ticket); return }
        print("Created ticket \(ticket.id ?? 0)".green + " from \(device)/\(item) error")
    }
}
