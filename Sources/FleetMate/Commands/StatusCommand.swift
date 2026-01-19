import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get fleet status overview from ReportMate and Snipe-IT"
    )
    
    @Flag(name: .shortAndLong, help: "Include detailed breakdown")
    var verbose: Bool = false
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        var status = FleetStatus()
        
        // Gather ReportMate stats (primary fleet monitoring)
        if config.isReportMateConfigured {
            let reportMateService = ReportMateService(config: config)
            do {
                let stats = try await reportMateService.getFleetStats()
                let devices = try await reportMateService.getDevices()
                let errors = try await reportMateService.getErrors()
                
                // Calculate stale devices (no check-in for 7+ days)
                let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                
                let staleCount = devices.filter { device in
                    guard let lastSeen = device.lastSeen else {
                        return true // Consider devices with no date as stale
                    }
                    return lastSeen < sevenDaysAgo
                }.count
                
                status.reportMate = ReportMateStatus(
                    totalDevices: devices.count,
                    staleDevices: staleCount,
                    totalErrors: errors.count,
                    totalInstalls: stats.totalInstalls,
                    pendingInstalls: stats.pendingInstalls,
                    connected: true
                )
            } catch {
                status.reportMate = ReportMateStatus(connected: false, error: error.localizedDescription)
            }
        }
        
        // Fallback to legacy MunkiReport if configured
        if status.reportMate == nil {
            let munkiService = MunkiReportService(config: config)
            do {
                let stats = try await munkiService.getInstallStats()
                let devices = try await munkiService.getDevices()
                let stale = try await munkiService.getStaleDevices(days: 7)
                let errors = try await munkiService.getErrors()
                
                // Sum up total installs from all items
                let totalInstalls = stats.reduce(0) { $0 + $1.installedCount }
                let pendingInstalls = stats.reduce(0) { $0 + ($1.totalDevices - $1.installedCount - $1.failedCount) }
                
                status.reportMate = ReportMateStatus(
                    totalDevices: devices.count,
                    staleDevices: stale.count,
                    totalErrors: errors.count,
                    totalInstalls: totalInstalls,
                    pendingInstalls: pendingInstalls,
                    connected: true,
                    isLegacy: true
                )
            } catch {
                status.reportMate = ReportMateStatus(connected: false, error: error.localizedDescription)
            }
        }
        
        // Gather Snipe-IT stats
        let snipeService = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey, cacheMinutes: config.cacheMinutes)
        
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
        
        // ReportMate Section
        let reportTitle = status.reportMate?.isLegacy == true ? "MunkiReport (Legacy)" : "ReportMate"
        print("📊 " + reportTitle.bold.cyan)
        if let rm = status.reportMate {
            if rm.connected {
                print("   Status:".lightBlue + "        " + "Connected".green)
                print("   Total Devices:".lightBlue + " \(rm.totalDevices)")
                print("   Stale (7d+):".lightBlue + "   " + formatCount(rm.staleDevices, warning: 5, critical: 20))
                print("   Errors:".lightBlue + "        " + formatCount(rm.totalErrors, warning: 1, critical: 10))
                print("   Pending:".lightBlue + "       " + formatCount(rm.pendingInstalls, warning: 10, critical: 50))
                if rm.isLegacy {
                    print("   ⚠️  " + "Consider migrating to ReportMate".yellow)
                }
            } else {
                print("   Status:".lightBlue + "        " + "Disconnected".red)
                if let error = rm.error {
                    print("   Error:".lightBlue + "         \(error)")
                }
            }
        } else {
            print("   Status:".lightBlue + "        " + "Not Configured".yellow)
            print("   " + "Run 'fleetmate configure' to set up".lightBlack)
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
        
        // Configuration hint
        if verbose {
            print("")
            print("🔧 " + "Configuration".bold.cyan)
            let config = try? FleetMateConfig.load()
            print("   ReportMate:".lightBlue + "    " + (config?.isReportMateConfigured == true ? "✅" : "❌"))
            print("   Snipe-IT:".lightBlue + "      " + (config?.snipeApiKey != nil ? "✅" : "❌"))
            print("   Graph/Entra:".lightBlue + "   " + (config?.graphTenantId != nil ? "✅" : "❌"))
            print("   SecureShell:".lightBlue + "   " + (config?.isSecureShellConfigured == true ? "✅" : "❌"))
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
    var reportMate: ReportMateStatus?
    var snipeIT: SnipeITStatus?
    var timestamp: String = ISO8601DateFormatter().string(from: Date())
}

struct ReportMateStatus: Codable {
    var totalDevices: Int = 0
    var staleDevices: Int = 0
    var totalErrors: Int = 0
    var totalInstalls: Int = 0
    var pendingInstalls: Int = 0
    var connected: Bool = false
    var error: String?
    var isLegacy: Bool = false  // True if using MunkiReport fallback
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
