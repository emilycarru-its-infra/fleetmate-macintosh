import ArgumentParser
import Foundation
import Rainbow
import FleetMateCore

struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate Munki repository structure and references"
    )
    
    @Option(name: .shortAndLong, help: "Path to deployment folder (defaults to config)")
    var path: String?
    
    @Flag(name: .shortAndLong, help: "Show all issues including warnings")
    var verbose: Bool = false
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let deploymentPath = path ?? config.deploymentPath
        
        guard !deploymentPath.isEmpty else {
            print("Deployment path not configured. Use --path or set FLEETMATE_DEPLOYMENT_PATH.".red)
            throw ExitCode.failure
        }
        
        let service = PkgInfoService(deploymentPath: deploymentPath)
        
        print("\n" + "Validating Munki repository...".bold + "\n")
        
        let result = try service.validate()
        
        if json {
            let output: [String: Any] = [
                "valid": result.isValid,
                "pkginfo_count": result.pkgInfoCount,
                "catalog_count": result.catalogCount,
                "manifest_count": result.manifestCount,
                "error_count": result.errors.count,
                "warning_count": result.warnings.count
            ]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            printResults(result, verbose: verbose, path: deploymentPath)
        }
        
        if !result.isValid {
            throw ExitCode.failure
        }
    }
    
    private func printResults(_ result: ValidationResult, verbose: Bool, path: String) {
        print("📁 Repository:".lightBlue + " \(path)")
        print("📦 PkgInfo files:".lightBlue + " \(result.pkgInfoCount)")
        print("📚 Catalogs:".lightBlue + " \(result.catalogCount)")
        print("📋 Manifests:".lightBlue + " \(result.manifestCount)")
        print("")
        
        if result.errors.isEmpty && result.warnings.isEmpty {
            print("✅ " + "Repository is valid!".green.bold + "\n")
            return
        }
        
        if !result.errors.isEmpty {
            print("❌ " + "Errors (\(result.errors.count))".red.bold + "\n")
            for error in result.errors {
                print("  • ".red + error.message)
                print("    " + error.path.lightBlack)
            }
            print("")
        }
        
        if verbose && !result.warnings.isEmpty {
            print("⚠️  " + "Warnings (\(result.warnings.count))".yellow.bold + "\n")
            for warning in result.warnings {
                print("  • ".yellow + warning.message)
                print("    " + warning.path.lightBlack)
            }
            print("")
        } else if !result.warnings.isEmpty {
            print("⚠️  \(result.warnings.count) warnings (use --verbose to show)".yellow + "\n")
        }
        
        if result.isValid {
            print("✅ " + "Repository structure is valid".green + " (with warnings)\n")
        } else {
            print("❌ " + "Repository has errors that must be fixed".red + "\n")
        }
    }
}

struct LintCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lint",
        abstract: "Lint Munki pkgsinfo files for best practices"
    )
    
    @Option(name: .shortAndLong, help: "Path to deployment folder")
    var path: String?
    
    @Option(name: .shortAndLong, help: "Filter by rule (naming, documentation, categorization, catalogs, uninstall)")
    var rule: String?
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let deploymentPath = path ?? config.deploymentPath
        
        guard !deploymentPath.isEmpty else {
            print("Deployment path not configured.".red)
            throw ExitCode.failure
        }
        
        let service = PkgInfoService(deploymentPath: deploymentPath)
        
        print("\n" + "Linting Munki pkgsinfo files...".bold + "\n")
        
        var issues = try service.lint()
        
        if let rule = rule {
            issues = issues.filter { $0.rule == rule }
        }
        
        if json {
            let output = issues.map { [
                "path": $0.path,
                "rule": $0.rule,
                "message": $0.message
            ]}
            if let data = try? JSONSerialization.data(withJSONObject: output, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            printIssues(issues)
        }
    }
    
    private func printIssues(_ issues: [LintIssue]) {
        if issues.isEmpty {
            print("✅ " + "No lint issues found!".green.bold + "\n")
            return
        }
        
        // Group by rule
        let grouped = Dictionary(grouping: issues) { $0.rule }
        
        print("Found \(issues.count) issues:\n".yellow)
        
        for (rule, ruleIssues) in grouped.sorted(by: { $0.key < $1.key }) {
            let icon = ruleIcon(rule)
            print("\(icon) " + "\(rule.capitalized)".bold + " (\(ruleIssues.count) issues)")
            
            for issue in ruleIssues.prefix(10) {
                let relativePath = (issue.path as NSString).lastPathComponent
                print("  • \(issue.message)".lightBlue)
                print("    \(relativePath)".lightBlack)
            }
            
            if ruleIssues.count > 10 {
                print("    ... and \(ruleIssues.count - 10) more".lightBlack)
            }
            print("")
        }
    }
    
    private func ruleIcon(_ rule: String) -> String {
        switch rule {
        case "naming": return "📛"
        case "documentation": return "📝"
        case "categorization": return "🏷️"
        case "catalogs": return "📚"
        case "uninstall": return "🗑️"
        default: return "🔍"
        }
    }
}
