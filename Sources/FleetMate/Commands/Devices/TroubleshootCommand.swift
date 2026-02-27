import ArgumentParser
import Foundation
import FleetMateCore
import Rainbow

/// Troubleshoot command - Diagnose and remediate installation failures
struct TroubleshootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "troubleshoot",
        abstract: "Diagnose and remediate installation failures",
        discussion: """
            Analyze installation errors and provide remediation suggestions.
            Can target a specific item or device for focused diagnostics.
            """
    )
    
    @Argument(help: "Item name, device serial, or 'fleet' for fleet-wide analysis")
    var target: String
    
    @Flag(name: .shortAndLong, help: "Attempt automatic remediation")
    var fix: Bool = false
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    @Flag(name: .shortAndLong, help: "Show verbose diagnostic output")
    var verbose: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isReportMateConfigured else {
            print("[ERROR] ReportMate not configured.".red)
            throw ExitCode.failure
        }
        
        let reportMate = ReportMateService(config: config)
        
        if target.lowercased() == "fleet" {
            try await troubleshootFleet(reportMate: reportMate)
        } else {
            // Determine if target is a device or an item
            let errors = try await reportMate.getErrors()
            
            let isDevice = errors.contains { 
                $0.serialNumber.lowercased() == target.lowercased() ||
                $0.deviceName.lowercased().contains(target.lowercased())
            }
            
            let isItem = errors.contains {
                $0.itemName.lowercased() == target.lowercased() ||
                $0.itemName.lowercased().contains(target.lowercased())
            }
            
            if isDevice && !isItem {
                try await troubleshootDevice(serial: target, reportMate: reportMate, config: config)
            } else if isItem {
                try await troubleshootItem(itemName: target, reportMate: reportMate, config: config)
            } else {
                // Try both approaches
                print("ℹ️  Searching for '\(target)' as both item and device...".cyan)
                try await troubleshootItem(itemName: target, reportMate: reportMate, config: config)
            }
        }
    }
    
    // MARK: - Fleet-wide Troubleshooting
    
    private func troubleshootFleet(reportMate: ReportMateService) async throws {
        print("\n" + "🔍 Fleet-Wide Error Analysis".bold + "\n")
        
        let errorsByItem = try await reportMate.getErrorsByItem()
        let errorsByDevice = try await reportMate.getErrorsByDevice()
        
        if errorsByItem.isEmpty && errorsByDevice.isEmpty {
            print("[ok] No errors found in the fleet!".green.bold)
            return
        }
        
        // Analyze patterns
        let analysis = FleetAnalysis(
            totalErrorItems: errorsByItem.count,
            totalAffectedDevices: errorsByDevice.count,
            topFailingItems: Array(errorsByItem.prefix(5)),
            topProblematicDevices: Array(errorsByDevice.prefix(5)),
            categoryBreakdown: categorizeErrors(errorsByItem)
        )
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(analysis)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printFleetAnalysis(analysis)
        }
    }
    
    private func categorizeErrors(_ errors: [ErrorSummary]) -> [String: Int] {
        var categories: [String: Int] = [:]
        for error in errors {
            categories[error.category.rawValue, default: 0] += error.deviceCount
        }
        return categories
    }
    
    private func printFleetAnalysis(_ analysis: FleetAnalysis) {
        print("Summary".bold)
        print("  Failing items: \(analysis.totalErrorItems)")
        print("  Affected devices: \(analysis.totalAffectedDevices)")
        print("")
        
        print("Top Failing Items".bold.red)
        for item in analysis.topFailingItems {
            let emoji = item.category.emoji
            print("  \(emoji) \(item.itemName) - \(item.deviceCount) devices (\(item.category.rawValue))")
        }
        print("")
        
        print("Most Problematic Devices".bold.yellow)
        for device in analysis.topProblematicDevices {
            print("  💻 \(device.deviceName) (\(device.serialNumber)) - \(device.errorCount) errors")
        }
        print("")
        
        print("Error Categories".bold)
        for (category, count) in analysis.categoryBreakdown.sorted(by: { $0.value > $1.value }) {
            print("  \(category): \(count)")
        }
        print("")
        
        print("Recommendations".bold.green)
        printFleetRecommendations(analysis)
    }
    
    private func printFleetRecommendations(_ analysis: FleetAnalysis) {
        // Analyze patterns and give recommendations
        if let topItem = analysis.topFailingItems.first {
            switch topItem.category {
            case .notFound:
                print("  1. Check that '\(topItem.itemName)' exists in the Munki repo")
                print("  2. Run 'makecatalogs' to update the catalogs")
                print("  3. Verify the item is in the correct catalog")
            case .hashMismatch:
                print("  1. Re-import '\(topItem.itemName)' with munkiimport")
                print("  2. Verify file integrity in the Munki repo")
                print("  3. Check for network issues during download")
            case .pkgFailure:
                print("  1. Test '\(topItem.itemName)' installer manually")
                print("  2. Check installer logs on affected devices")
                print("  3. Verify package compatibility with target OS")
            case .installVerificationFailed:
                print("  1. Review postinstall scripts for '\(topItem.itemName)'")
                print("  2. Check script permissions and dependencies")
                print("  3. Test scripts in isolation")
            case .diskFull:
                print("  1. Check disk space on affected devices")
                print("  2. Consider package size optimization")
                print("  3. Implement disk cleanup policies")
            case .signatureRequired:
                print("  1. Sign the package with a valid Developer ID")
                print("  2. Or disable signature requirement in Munki config")
                print("  3. Check Gatekeeper settings on affected devices")
            case .downloadFailed:
                print("  1. Check Munki repo availability")
                print("  2. Verify CDN/distribution points")
                print("  3. Review firewall rules for affected devices")
            case .catalogMissing:
                print("  1. Run makecatalogs on the Munki repo")
                print("  2. Verify item is in a catalog")
                print("  3. Check manifest catalog assignments")
            case .missingInstallerLocation:
                print("  1. Check pkginfo has installer_item_location")
                print("  2. Verify the pkg file exists in the repo")
                print("  3. Re-import the package with munkiimport")
            case .unknown, .other:
                print("  1. Review individual error messages")
                print("  2. Check Munki logs on affected devices")
                print("  3. Contact package maintainer")
            }
        }
    }
    
    // MARK: - Item Troubleshooting
    
    private func troubleshootItem(itemName: String, reportMate: ReportMateService, config: FleetMateConfig) async throws {
        print("\n" + "🔍 Troubleshooting: ".bold + itemName.cyan + "\n")
        
        let allErrors = try await reportMate.getErrors()
        let itemErrors = allErrors.filter { 
            $0.itemName.lowercased().contains(itemName.lowercased())
        }
        
        if itemErrors.isEmpty {
            print("[ok] No errors found for '\(itemName)'".green)
            return
        }
        
        // Group by category
        var byCategory: [ErrorCategory: [InstallRecord]] = [:]
        for error in itemErrors {
            byCategory[error.category, default: []].append(error)
        }
        
        let diagnosis = ItemDiagnosis(
            itemName: itemName,
            totalErrors: itemErrors.count,
            affectedDevices: Array(Set(itemErrors.map { $0.serialNumber })),
            categories: byCategory.mapValues { $0.count },
            sampleErrors: Array(itemErrors.prefix(5))
        )
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ItemDiagnosisOutput(from: diagnosis))
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printItemDiagnosis(diagnosis)
            
            if fix && config.isSecureShellConfigured {
                try await attemptItemRemediation(diagnosis: diagnosis, config: config)
            }
        }
    }
    
    private func printItemDiagnosis(_ diagnosis: ItemDiagnosis) {
        print("Affected Devices: ".bold + "\(diagnosis.affectedDevices.count)")
        print("Total Errors: ".bold + "\(diagnosis.totalErrors)")
        print("")
        
        print("Error Categories:".bold)
        for (category, count) in diagnosis.categories.sorted(by: { $0.value > $1.value }) {
            print("  \(category.emoji) \(category.rawValue): \(count)")
        }
        print("")
        
        if verbose {
            print("Sample Errors:".bold)
            for error in diagnosis.sampleErrors {
                print("  \(error.deviceName.cyan) - \(error.currentStatus)")
                if let msg = error.lastError {
                    print("    └─ \(msg.prefix(80))")
                }
            }
            print("")
        }
        
        print("Remediation Steps:".bold.green)
        printItemRemediation(diagnosis)
    }
    
    private func printItemRemediation(_ diagnosis: ItemDiagnosis) {
        let primaryCategory = diagnosis.categories.max(by: { $0.value < $1.value })?.key ?? .unknown
        
        switch primaryCategory {
        case .notFound:
            print("  1. Verify the item exists in the Munki repository:")
            print("     makecatalogs /path/to/munki_repo".lightBlack)
            print("  2. Check the catalog assignment for the item")
            print("  3. Ensure manifest includes the correct catalog")
            
        case .hashMismatch:
            print("  1. Re-import the package to regenerate hashes:")
            print("     munkiimport /path/to/\(diagnosis.itemName).pkg".lightBlack)
            print("  2. Force a cache clear on affected devices:")
            print("     rm -rf /Library/Managed\\ Installs/Cache/*".lightBlack)
            print("  3. Run Munki check again")
            
        case .pkgFailure:
            print("  1. Test the installer manually on a device")
            print("  2. Check /var/log/install.log for details")
            print("  3. Verify package signing and notarization")
            print("  4. Consider repackaging with a newer installer")
            
        case .installVerificationFailed:
            print("  1. Review postinstall scripts")
            print("  2. Ensure all script dependencies are available")
            print("  3. Test scripts with 'bash -x script.sh'")
            print("  4. Check for hardcoded paths that may have changed")
            
        case .diskFull:
            print("  1. Free up disk space on affected devices")
            print("  2. Use 'fleetmate ssh <device> df -h' to check space")
            print("  3. Consider implementing automated disk cleanup")
            
        case .signatureRequired:
            print("  1. Sign the package with a valid Developer ID")
            print("  2. Or configure Munki to allow unsigned packages")
            print("  3. Check Gatekeeper settings on affected devices")
            
        case .downloadFailed:
            print("  1. Check Munki repo URL accessibility")
            print("  2. Verify DNS resolution on affected devices")
            print("  3. Check for proxy or firewall issues")
            
        case .catalogMissing:
            print("  1. Run makecatalogs on the Munki repo")
            print("  2. Verify item is in a catalog")
            print("  3. Check manifest catalog assignments")
            
        case .missingInstallerLocation:
            print("  1. Check pkginfo has installer_item_location")
            print("  2. Verify the pkg file exists in the repo")
            print("  3. Re-import the package with munkiimport")
            
        case .unknown, .other:
            print("  1. Review full error logs on an affected device:")
            print("     fleetmate ssh <device> logs".lightBlack)
            print("  2. Check ManagedSoftwareUpdate.log for details")
            print("  3. Contact the package maintainer")
        }
    }
    
    private func attemptItemRemediation(diagnosis: ItemDiagnosis, config: FleetMateConfig) async throws {
        print("\n" + "Attempting Automatic Remediation...".bold.yellow + "\n")
        
        let primaryCategory = diagnosis.categories.max(by: { $0.value < $1.value })?.key ?? .unknown
        let sshService = SecureShellService(fleetConfig: config)
        
        // Only attempt safe remediations
        switch primaryCategory {
        case .hashMismatch:
            print("Clearing Munki cache on affected devices...")
            for serial in diagnosis.affectedDevices.prefix(3) {
                let result = try await sshService.execute(
                    host: serial,
                    command: "sudo rm -rf /Library/Managed\\ Installs/Cache/*"
                )
                let status = result.exitCode == 0 ? "yes" : "no"
                print("  \(status) \(serial)")
            }
            
        case .downloadFailed:
            print("Testing Munki repo connectivity on affected devices...")
            for serial in diagnosis.affectedDevices.prefix(3) {
                let result = try await sshService.execute(
                    host: serial,
                    command: "defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL | xargs curl -sI"
                )
                let status = result.exitCode == 0 ? "yes" : "no"
                print("  \(status) \(serial)")
            }
            
        default:
            print("[WARNING] Automatic remediation not available for \(primaryCategory.rawValue) errors.".yellow)
            print("   Please follow the manual steps above.")
        }
    }
    
    // MARK: - Device Troubleshooting
    
    private func troubleshootDevice(serial: String, reportMate: ReportMateService, config: FleetMateConfig) async throws {
        print("\n" + "🔍 Troubleshooting Device: ".bold + serial.cyan + "\n")
        
        // Get device info
        let device = try await reportMate.findDevice(serial)
        
        if let dev = device {
            print("Device: ".bold + dev.displayName)
            print("Serial: ".bold + dev.serialNumber)
            let lastSeenStr = dev.lastSeen.map { ISO8601DateFormatter().string(from: $0) } ?? "Unknown"
            print("Last Check-in: ".bold + lastSeenStr)
            print("")
        }
        
        // Get errors for this device
        let allErrors = try await reportMate.getErrors()
        let deviceErrors = allErrors.filter { 
            $0.serialNumber.lowercased() == serial.lowercased() ||
            $0.deviceName.lowercased().contains(serial.lowercased())
        }
        
        if deviceErrors.isEmpty {
            print("[ok] No errors found for this device".green)
            return
        }
        
        print("Failing Items (\(deviceErrors.count)):".bold.red)
        for error in deviceErrors {
            let emoji = error.category.emoji
            print("  \(emoji) \(error.itemName) - \(error.category.rawValue)")
            if verbose, let msg = error.lastError {
                print("     └─ \(msg.prefix(60))")
            }
        }
        print("")
        
        // Recommendations
        print("Recommended Actions:".bold.green)
        print("  1. Check device connectivity:")
        print("     fleetmate ssh test \(serial)".lightBlack)
        print("  2. View Munki logs:")
        print("     fleetmate ssh logs \(serial)".lightBlack)
        print("  3. Run Munki check:")
        print("     fleetmate ssh munki check \(serial)".lightBlack)
        print("  4. Clear cache and retry:")
        print("     fleetmate ssh exec \(serial) -- sudo rm -rf /Library/Managed\\ Installs/Cache/*".lightBlack)
        
        if fix && config.isSecureShellConfigured {
            print("\n" + "Running automated diagnostics...".bold.yellow + "\n")
            
            let sshService = SecureShellService(fleetConfig: config)
            
            // Test connectivity
            print("Testing SSH connectivity... ", terminator: "")
            let testResult = try await sshService.testConnection(host: serial)
            print(testResult.success ? "yes" : "no")
            
            if testResult.success {
                // Get disk space
                print("Checking disk space... ", terminator: "")
                let diskResult = try await sshService.execute(host: serial, command: "df -h / | tail -1 | awk '{print $5}'")
                let usage = diskResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                print(usage)
                
                // Get last Munki run
                print("Last Munki run... ", terminator: "")
                let lastRunResult = try await sshService.execute(
                    host: serial,
                    command: "stat -f '%Sm' '/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log' 2>/dev/null || echo 'Unknown'"
                )
                print(lastRunResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

// MARK: - Models

struct FleetAnalysis: Codable {
    let totalErrorItems: Int
    let totalAffectedDevices: Int
    let topFailingItems: [ErrorSummary]
    let topProblematicDevices: [DeviceErrorSummary]
    let categoryBreakdown: [String: Int]
}

struct ItemDiagnosis {
    let itemName: String
    let totalErrors: Int
    let affectedDevices: [String]
    let categories: [ErrorCategory: Int]
    let sampleErrors: [InstallRecord]
}

struct ItemDiagnosisOutput: Codable {
    let itemName: String
    let totalErrors: Int
    let affectedDevices: [String]
    let categories: [String: Int]
    
    init(from diagnosis: ItemDiagnosis) {
        self.itemName = diagnosis.itemName
        self.totalErrors = diagnosis.totalErrors
        self.affectedDevices = diagnosis.affectedDevices
        self.categories = Dictionary(uniqueKeysWithValues: diagnosis.categories.map { ($0.key.rawValue, $0.value) })
    }
}
