import ArgumentParser
import Foundation
import FleetMateCore
import Rainbow

/// Device lookup and information command (equivalent to Windows DeviceCommand)
struct DeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Look up a device by serial, hostname, or asset tag",
        discussion: "Query ReportMate and Snipe-IT for device information and installation status."
    )
    
    @Argument(help: "Serial number, hostname, asset tag, or MAC address")
    var query: String
    
    @Flag(name: .shortAndLong, help: "Show installation details")
    var installs: Bool = false
    
    @Flag(name: .shortAndLong, help: "Show only errors and warnings")
    var errorsOnly: Bool = false
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        // Initialize services
        let reportMate = config.isReportMateConfigured ? 
            ReportMateService(config: config) : nil
        let snipe = config.isSnipeConfigured ?
            SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey) : nil
        
        var deviceInfo = DeviceInfo()
        deviceInfo.query = query
        
        // Query ReportMate
        if let rm = reportMate {
            if let device = try await rm.findDevice(query) {
                deviceInfo.reportMate = device
                
                // Get installs if requested
                if installs || errorsOnly {
                    var deviceInstalls = try await rm.getDeviceInstalls(device.serialNumber)
                    if errorsOnly {
                        deviceInstalls = deviceInstalls.filter { $0.isError }
                    }
                    deviceInfo.installs = deviceInstalls
                }
            }
        }
        
        // Query Snipe-IT
        if let snipeService = snipe {
            // Try by serial first
            if let asset = try await snipeService.getAssetBySerial(query) {
                deviceInfo.snipeAsset = asset
            } else if let asset = try await snipeService.getAssetByTag(query) {
                deviceInfo.snipeAsset = asset
            } else {
                // Search by name
                let assets = try await snipeService.getAssets(search: query)
                deviceInfo.snipeAsset = assets.first
            }
        }
        
        // Check if we found anything
        if deviceInfo.reportMate == nil && deviceInfo.snipeAsset == nil {
            print("\n" + "[ERROR] Device not found: ".red + query.bold + "\n")
            print("Searched in:")
            if reportMate != nil {
                print("  • ReportMate: No device matching '\(query)'")
            } else {
                print("  • ReportMate: Not configured".yellow)
            }
            if snipe != nil {
                print("  • Snipe-IT: No asset matching '\(query)'")
            } else {
                print("  • Snipe-IT: Not configured".yellow)
            }
            print("")
            throw ExitCode.failure
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(deviceInfo)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printDeviceInfo(deviceInfo)
        }
    }
    
    private func printDeviceInfo(_ info: DeviceInfo) {
        print("\n" + "═══════════════════════════════════════════════════════".bold)
        
        // Header with device name
        let displayName: String
        if let rm = info.reportMate {
            displayName = rm.displayName
        } else if let snipe = info.snipeAsset {
            displayName = snipe.name ?? snipe.assetTag ?? "Unknown"
        } else {
            displayName = info.query
        }
        
        print("  📱 " + displayName.bold.green)
        print("═══════════════════════════════════════════════════════".bold + "\n")
        
        // ReportMate info
        if let rm = info.reportMate {
            print("" + "ReportMate".bold.cyan)
            print("   Serial:".lightBlue + "       \(rm.serialNumber)")
            print("   Hostname:".lightBlue + "     \(rm.hostname.isEmpty ? "N/A" : rm.hostname)")
            print("   Device Name:".lightBlue + "  \(rm.deviceName.isEmpty ? "N/A" : rm.deviceName)")
            print("   Owner:".lightBlue + "        \(rm.owner.isEmpty ? "N/A" : rm.owner)")
            print("   OS Version:".lightBlue + "   \(rm.osVersion.isEmpty ? "N/A" : rm.osVersion) (\(rm.osBuild))")
            print("   Model:".lightBlue + "        \(rm.manufacturer) \(rm.model)")
            print("   IP Address:".lightBlue + "   \(rm.ipAddress.isEmpty ? "N/A" : rm.ipAddress)")
            print("   Location:".lightBlue + "     \(rm.location.isEmpty ? "N/A" : rm.location)")
            print("   Catalog:".lightBlue + "      \(rm.catalog.isEmpty ? "N/A" : rm.catalog)")
            
            if let lastSeen = rm.lastSeen {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                let relative = formatter.localizedString(for: lastSeen, relativeTo: Date())
                print("   Last Seen:".lightBlue + "    \(relative)")
            }
            print("")
        }
        
        // Snipe-IT info
        if let snipe = info.snipeAsset {
            print("" + "Snipe-IT".bold.cyan)
            print("   Asset Tag:".lightBlue + "    \(snipe.assetTag ?? "N/A")")
            print("   Name:".lightBlue + "         \(snipe.name ?? "N/A")")
            print("   Serial:".lightBlue + "       \(snipe.serial ?? "N/A")")
            print("   Model:".lightBlue + "        \(snipe.model?.name ?? "N/A")")
            print("   Status:".lightBlue + "       \(snipe.statusLabel?.name ?? "N/A")")
            print("   Location:".lightBlue + "     \(snipe.location?.name ?? "N/A")")
            if let user = snipe.assignedTo {
                print("   Assigned To:".lightBlue + "  \(user.name ?? "N/A")")
            }
            print("")
        }
        
        // Installation details
        if let installs = info.installs, !installs.isEmpty {
            let errors = installs.filter { $0.isError }
            let title = errorsOnly ? "Installation Errors" : "Installations"
            print("📋 " + title.bold.cyan + " (\(installs.count) items, \(errors.count) errors)\n")
            
            for install in installs.prefix(25) {
                let statusIcon: String
                let statusColor: String
                
                if install.isError {
                    statusIcon = "[error]"
                    statusColor = install.itemName.red
                } else if install.installedVersion.isEmpty {
                    statusIcon = "⏳"
                    statusColor = install.itemName.yellow
                } else {
                    statusIcon = "[ok]"
                    statusColor = install.itemName.green
                }
                
                print("   \(statusIcon) " + statusColor)
                print("      Version: \(install.installedVersion.isEmpty ? "Not installed" : install.installedVersion)")
                if install.isError, let error = install.lastError {
                    print("      Error: \(error)".red)
                }
            }
            
            if installs.count > 25 {
                print("\n   ... and \(installs.count - 25) more items")
            }
            print("")
        }
        
        print("═══════════════════════════════════════════════════════".bold + "\n")
    }
}

// MARK: - Device Info Model

struct DeviceInfo: Codable {
    var query: String = ""
    var reportMate: ReportMateDevice?
    var snipeAsset: SnipeAsset?
    var installs: [InstallRecord]?
}
