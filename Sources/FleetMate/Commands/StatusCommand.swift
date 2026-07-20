import ArgumentParser
import Foundation
import Rainbow
import FleetMateCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get fleet status overview from MunkiReport and Snipe-IT"
    )
    
    @Flag(name: .shortAndLong, help: "Include detailed breakdown")
    var verbose: Bool = false
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        var status = FleetStatus()
        
        // Gather MunkiReport stats
        let munkiService = MunkiReportService(config: config)
        do {
            let stats = try await munkiService.getInstallStats()
            let devices = try await munkiService.getDevices()
            let stale = try await munkiService.getStaleDevices(days: 7)
            let errors = try await munkiService.getErrors()
            
            // Aggregate stats from all items
            let totalInstalls = stats.reduce(0) { $0 + $1.installedCount }
            let pendingCount = stats.reduce(0) { $0 + $1.failedCount }
            
            status.munkiReport = MunkiReportStatus(
                totalDevices: devices.count,
                staleDevices: stale.count,
                totalErrors: errors.count,
                totalInstalls: totalInstalls,
                pendingInstalls: pendingCount,
                connected: true
            )
        } catch {
            status.munkiReport = MunkiReportStatus(connected: false, error: error.localizedDescription)
        }
        
        // Gather Snipe-IT stats
        let snipeService = SnipeService(config: config)
        
        if snipeService.isConfigured {
            do {
                let assets = try await snipeService.getAssets()
                let locations = try await snipeService.getLocations()
                
                let deployed = assets.filter { $0.statusLabel?.statusMeta == "deployed" }.count
                let ready = assets.filter { $0.statusLabel?.statusMeta == "deployable" }.count
                let archived = assets.filter { $0.statusLabel?.statusMeta == "archived" }.count
                
                status.snipeIT = SnipeITStatus(
                    totalAssets: assets.count,
                    deployedAssets: deployed,
                    readyToDeploy: ready,
                    archivedAssets: archived,
                    locations: locations.count,
                    connected: true
                )
            } catch {
                status.snipeIT = SnipeITStatus(connected: false, error: error.localizedDescription)
            }
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(status)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printStatus(status, verbose: verbose)
        }
    }
    
    private func printStatus(_ status: FleetStatus, verbose: Bool) {
        print("\n" + "═══════════════════════════════════════════════════════".bold)
        print("                   " + "FleetMate Status".bold.green)
        print("═══════════════════════════════════════════════════════".bold + "\n")
        
        // MunkiReport Section
        print("📊 " + "MunkiReport".bold.cyan)
        if let mr = status.munkiReport {
            if mr.connected {
                print("   Status:".lightBlue + "        " + "Connected".green)
                print("   Total Devices:".lightBlue + " \(mr.totalDevices)")
                print("   Stale (7d+):".lightBlue + "   " + formatCount(mr.staleDevices, warning: 5, critical: 20))
                print("   Errors:".lightBlue + "        " + formatCount(mr.totalErrors, warning: 1, critical: 10))
                print("   Pending:".lightBlue + "       " + formatCount(mr.pendingInstalls, warning: 10, critical: 50))
            } else {
                print("   Status:".lightBlue + "        " + "Disconnected".red)
                if let error = mr.error {
                    print("   Error:".lightBlue + "         \(error)")
                }
            }
        } else {
            print("   Status:".lightBlue + "        " + "Not Configured".yellow)
        }
        
        print("")
        
        // Snipe-IT Section
        print("📦 " + "Snipe-IT".bold.cyan)
        if let snipe = status.snipeIT {
            if snipe.connected {
                print("   Status:".lightBlue + "        " + "Connected".green)
                print("   Total Assets:".lightBlue + "  \(snipe.totalAssets)")
                print("   Deployed:".lightBlue + "      \(snipe.deployedAssets)")
                print("   Ready:".lightBlue + "         \(snipe.readyToDeploy)")
                print("   Archived:".lightBlue + "      \(snipe.archivedAssets)")
                print("   Locations:".lightBlue + "     \(snipe.locations)")
            } else {
                print("   Status:".lightBlue + "        " + "Disconnected".red)
                if let error = snipe.error {
                    print("   Error:".lightBlue + "         \(error)")
                }
            }
        } else {
            print("   Status:".lightBlue + "        " + "Not Configured".yellow)
        }
        
        print("\n" + "═══════════════════════════════════════════════════════".bold + "\n")
    }
    
    private func formatCount(_ count: Int, warning: Int, critical: Int) -> String {
        if count >= critical {
            return "\(count)".red
        } else if count >= warning {
            return "\(count)".yellow
        } else {
            return "\(count)".green
        }
    }
}

// MARK: - Status Models

struct FleetStatus: Codable {
    var munkiReport: MunkiReportStatus?
    var snipeIT: SnipeITStatus?
    var timestamp: String = ISO8601DateFormatter().string(from: Date())
}

struct MunkiReportStatus: Codable {
    var totalDevices: Int = 0
    var staleDevices: Int = 0
    var totalErrors: Int = 0
    var totalInstalls: Int = 0
    var pendingInstalls: Int = 0
    var connected: Bool = false
    var error: String?
}

struct SnipeITStatus: Codable {
    var totalAssets: Int = 0
    var deployedAssets: Int = 0
    var readyToDeploy: Int = 0
    var archivedAssets: Int = 0
    var locations: Int = 0
    var connected: Bool = false
    var error: String?
}
