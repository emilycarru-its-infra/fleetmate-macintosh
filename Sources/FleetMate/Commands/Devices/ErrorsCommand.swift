import ArgumentParser
import Foundation
import FleetMateCore
import Rainbow

/// Errors command - View installation errors across the fleet
struct ErrorsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "errors",
        abstract: "View installation errors across the fleet",
        discussion: "Query ReportMate for installation errors grouped by item or device.",
        subcommands: [
            ListErrorsSubcommand.self,
            ByItemSubcommand.self,
            ByDeviceSubcommand.self,
            ByCategorySubcommand.self
        ],
        defaultSubcommand: ListErrorsSubcommand.self
    )
}

// MARK: - List All Errors

struct ListErrorsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all installation errors"
    )
    
    @Option(name: .shortAndLong, help: "Maximum number of results")
    var limit: Int = 50
    
    @Option(name: .shortAndLong, help: "Filter by item name")
    var item: String?
    
    @Option(name: .shortAndLong, help: "Filter by device serial")
    var device: String?
    
    @Option(name: .shortAndLong, help: "Filter by error category")
    var category: String?
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isReportMateConfigured else {
            print("[ERROR] ReportMate not configured. Set REPORTMATE_URL and REPORTMATE_PASSPHRASE.".red)
            throw ExitCode.failure
        }
        
        let reportMate = ReportMateService(config: config)
        var errors = try await reportMate.getErrors()
        
        // Apply filters
        if let itemFilter = item {
            errors = errors.filter { $0.itemName.lowercased().contains(itemFilter.lowercased()) }
        }
        if let deviceFilter = device {
            errors = errors.filter { 
                $0.serialNumber.lowercased().contains(deviceFilter.lowercased()) ||
                $0.deviceName.lowercased().contains(deviceFilter.lowercased())
            }
        }
        if let categoryFilter = category {
            errors = errors.filter { $0.category.rawValue.lowercased().contains(categoryFilter.lowercased()) }
        }
        
        // Limit results
        if errors.count > limit {
            errors = Array(errors.prefix(limit))
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(errors)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printErrors(errors)
        }
    }
    
    private func printErrors(_ errors: [InstallRecord]) {
        if errors.isEmpty {
            print("\n" + "[ok] No errors found!".green + "\n")
            return
        }
        
        print("\n" + "Installation Errors".bold.red + " (\(errors.count) total)\n")
        
        for error in errors {
            let categoryEmoji = error.category.emoji
            print("\(categoryEmoji) " + error.itemName.bold.red + " on " + error.deviceName.cyan)
            print("   Serial:".lightBlue + "    \(error.serialNumber)")
            print("   Category:".lightBlue + "  \(error.category.rawValue)")
            print("   Status:".lightBlue + "    \(error.currentStatus)")
            if let errorMsg = error.lastError, !errorMsg.isEmpty {
                // Truncate long error messages
                let truncated = errorMsg.count > 100 ? String(errorMsg.prefix(100)) + "..." : errorMsg
                print("   Error:".lightBlue + "     \(truncated)")
            }
            print("")
        }
    }
}

// MARK: - Errors By Item

struct ByItemSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "by-item",
        abstract: "Group errors by item name"
    )
    
    @Option(name: .shortAndLong, help: "Maximum number of items to show")
    var limit: Int = 20
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isReportMateConfigured else {
            print("[ERROR] ReportMate not configured.".red)
            throw ExitCode.failure
        }
        
        let reportMate = ReportMateService(config: config)
        var summaries = try await reportMate.getErrorsByItem()
        
        if summaries.count > limit {
            summaries = Array(summaries.prefix(limit))
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(summaries.map { ErrorSummaryOutput(from: $0) })
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printErrorsByItem(summaries)
        }
    }
    
    private func printErrorsByItem(_ summaries: [ErrorSummary]) {
        if summaries.isEmpty {
            print("\n" + "[ok] No errors found!".green + "\n")
            return
        }
        
        print("\n" + "Errors by Item".bold.red + " (Top \(summaries.count) failing packages)\n")
        
        let header = "Item Name".col(40) + " " + "Devices".col(10) + " " + "Category".col(20)
        print(header.underline)

        for summary in summaries {
            let countCell = String(summary.deviceCount).col(10)
            let deviceCount = summary.deviceCount > 10 ?
                countCell.red :
                (summary.deviceCount > 5 ? countCell.yellow : countCell)

            let row = summary.itemName.col(40) + " "
                + deviceCount + " "
                + summary.category.rawValue.col(20)
            print(row)
        }
        
        print("\n" + "Tip:".bold + " Use 'fleetmate troubleshoot <item>' for remediation steps.\n")
    }
}

// MARK: - Errors By Device

struct ByDeviceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "by-device",
        abstract: "Group errors by device"
    )
    
    @Option(name: .shortAndLong, help: "Maximum number of devices to show")
    var limit: Int = 20
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isReportMateConfigured else {
            print("[ERROR] ReportMate not configured.".red)
            throw ExitCode.failure
        }
        
        let reportMate = ReportMateService(config: config)
        var summaries = try await reportMate.getErrorsByDevice()
        
        if summaries.count > limit {
            summaries = Array(summaries.prefix(limit))
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(summaries.map { DeviceErrorSummaryOutput(from: $0) })
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printErrorsByDevice(summaries)
        }
    }
    
    private func printErrorsByDevice(_ summaries: [DeviceErrorSummary]) {
        if summaries.isEmpty {
            print("\n" + "[ok] No devices with errors!".green + "\n")
            return
        }
        
        print("\n" + "Errors by Device".bold.red + " (Top \(summaries.count) problematic devices)\n")
        
        let header = "Serial".col(20) + " " + "Device Name".col(30) + " " + "Errors".col(10) + " " + "Location".col(20)
        print(header.underline)

        for summary in summaries {
            let countCell = String(summary.errorCount).col(10)
            let errorCount = summary.errorCount > 5 ?
                countCell.red :
                (summary.errorCount > 2 ? countCell.yellow : countCell)

            let row = summary.serialNumber.col(20) + " "
                + summary.deviceName.col(30) + " "
                + errorCount + " "
                + summary.location.col(20)
            print(row)
        }
        
        print("\n" + "Tip:".bold + " Use 'fleetmate device <serial> --errors-only' for device details.\n")
    }
}

// MARK: - Errors By Category

struct ByCategorySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "by-category",
        abstract: "Group errors by category"
    )
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isReportMateConfigured else {
            print("[ERROR] ReportMate not configured.".red)
            throw ExitCode.failure
        }
        
        let reportMate = ReportMateService(config: config)
        let errors = try await reportMate.getErrors()
        
        // Group by category
        var categoryGroups: [ErrorCategory: [InstallRecord]] = [:]
        for error in errors {
            categoryGroups[error.category, default: []].append(error)
        }
        
        let summaries = categoryGroups.map { (category, records) -> CategorySummary in
            CategorySummary(
                category: category,
                count: records.count,
                items: Array(Set(records.map { $0.itemName })).prefix(5).map { String($0) }
            )
        }.sorted { $0.count > $1.count }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(summaries)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printErrorsByCategory(summaries)
        }
    }
    
    private func printErrorsByCategory(_ summaries: [CategorySummary]) {
        if summaries.isEmpty {
            print("\n" + "[ok] No errors found!".green + "\n")
            return
        }
        
        print("\n" + "Errors by Category".bold.red + "\n")
        
        for summary in summaries {
            let emoji = summary.category.emoji
            print("\(emoji) " + summary.category.rawValue.bold + " (\(summary.count) errors)")
            print("   Sample items: \(summary.items.joined(separator: ", "))")
            print("")
        }
    }
}

// MARK: - Output Models

struct ErrorSummaryOutput: Codable {
    let itemName: String
    let deviceCount: Int
    let category: String
    let sampleError: String
    let affectedDevices: [String]
    
    init(from summary: ErrorSummary) {
        self.itemName = summary.itemName
        self.deviceCount = summary.deviceCount
        self.category = summary.category.rawValue
        self.sampleError = summary.sampleError
        self.affectedDevices = summary.affectedDevices
    }
}

struct DeviceErrorSummaryOutput: Codable {
    let deviceName: String
    let serialNumber: String
    let location: String
    let errorCount: Int
    let failedItems: [String]
    
    init(from summary: DeviceErrorSummary) {
        self.deviceName = summary.deviceName
        self.serialNumber = summary.serialNumber
        self.location = summary.location
        self.errorCount = summary.errorCount
        self.failedItems = summary.failedItems
    }
}

struct CategorySummary: Codable {
    let category: ErrorCategory
    let count: Int
    let items: [String]
}
