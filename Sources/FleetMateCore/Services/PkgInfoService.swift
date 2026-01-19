import Foundation
import Yams

/// Service for validating and linting Munki pkgsinfo files
public class PkgInfoService {
    let pkgsInfoPath: String
    let catalogsPath: String
    let manifestsPath: String
    
    public init(deploymentPath: String) {
        self.pkgsInfoPath = (deploymentPath as NSString).appendingPathComponent("pkgsinfo")
        self.catalogsPath = (deploymentPath as NSString).appendingPathComponent("catalogs")
        self.manifestsPath = (deploymentPath as NSString).appendingPathComponent("manifests")
    }
    
    // MARK: - PkgInfo Loading
    
    func loadAllPkgInfo() throws -> [PkgInfo] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pkgsInfoPath) else {
            throw PkgInfoError.pathNotFound(pkgsInfoPath)
        }
        
        var pkgInfos: [PkgInfo] = []
        
        let enumerator = fm.enumerator(atPath: pkgsInfoPath)
        while let file = enumerator?.nextObject() as? String {
            let fullPath = (pkgsInfoPath as NSString).appendingPathComponent(file)
            
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir) && !isDir.boolValue {
                // Skip hidden files
                if file.hasPrefix(".") || file.contains("/.") { continue }
                
                if let pkgInfo = try? loadPkgInfo(at: fullPath) {
                    pkgInfos.append(pkgInfo)
                }
            }
        }
        
        return pkgInfos
    }
    
    func loadPkgInfo(at path: String) throws -> PkgInfo {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        
        // Try YAML first (plist-style), then try property list
        if let content = String(data: data, encoding: .utf8),
           let yaml = try? Yams.load(yaml: content) as? [String: Any] {
            return PkgInfo(from: yaml, path: path)
        }
        
        // Try as property list
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return PkgInfo(from: plist, path: path)
        }
        
        throw PkgInfoError.parseError(path)
    }
    
    // MARK: - Catalogs
    
    func loadCatalogs() throws -> [String: [CatalogItem]] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: catalogsPath) else {
            return [:]
        }
        
        var catalogs: [String: [CatalogItem]] = [:]
        
        let files = try fm.contentsOfDirectory(atPath: catalogsPath)
        for file in files where !file.hasPrefix(".") {
            let fullPath = (catalogsPath as NSString).appendingPathComponent(file)
            
            if let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
                let items = plist.compactMap { CatalogItem(from: $0) }
                catalogs[file] = items
            }
        }
        
        return catalogs
    }
    
    // MARK: - Manifests
    
    func loadManifests() throws -> [ManifestFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestsPath) else {
            return []
        }
        
        var manifests: [ManifestFile] = []
        
        let enumerator = fm.enumerator(atPath: manifestsPath)
        while let file = enumerator?.nextObject() as? String {
            let fullPath = (manifestsPath as NSString).appendingPathComponent(file)
            
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir) && !isDir.boolValue {
                if file.hasPrefix(".") || file.contains("/.") { continue }
                
                if let manifest = try? loadManifest(at: fullPath, relativePath: file) {
                    manifests.append(manifest)
                }
            }
        }
        
        return manifests
    }
    
    func loadManifest(at path: String, relativePath: String) throws -> ManifestFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        
        // Try YAML first
        if let content = String(data: data, encoding: .utf8),
           let yaml = try? Yams.load(yaml: content) as? [String: Any] {
            return ManifestFile(from: yaml, path: relativePath)
        }
        
        // Try property list
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return ManifestFile(from: plist, path: relativePath)
        }
        
        throw PkgInfoError.parseError(path)
    }
    
    // MARK: - Validation
    
    public func validate() throws -> ValidationResult {
        var result = ValidationResult()
        
        // Load all data
        let pkgInfos = try loadAllPkgInfo()
        let catalogs = try loadCatalogs()
        let manifests = try loadManifests()
        
        result.pkgInfoCount = pkgInfos.count
        result.catalogCount = catalogs.count
        result.manifestCount = manifests.count
        
        // Build package name index
        let packageNames = Set(pkgInfos.map { $0.name })
        
        // Validate each pkginfo
        for pkg in pkgInfos {
            // Check required fields
            if pkg.name.isEmpty {
                result.errors.append(ValidationIssue(
                    path: pkg.path,
                    severity: .error,
                    message: "Missing required field: name"
                ))
            }
            
            if pkg.version.isEmpty {
                result.errors.append(ValidationIssue(
                    path: pkg.path,
                    severity: .error,
                    message: "Missing required field: version"
                ))
            }
            
            // Check installer references
            if let installerPath = pkg.installerItemLocation {
                let pkgPath = (pkgsInfoPath as NSString)
                    .deletingLastPathComponent
                    .appending("/pkgs/\(installerPath)")
                
                if !FileManager.default.fileExists(atPath: pkgPath) {
                    result.warnings.append(ValidationIssue(
                        path: pkg.path,
                        severity: .warning,
                        message: "Referenced installer not found: \(installerPath)"
                    ))
                }
            }
            
            // Check update_for references
            for updateFor in pkg.updateFor {
                if !packageNames.contains(updateFor) {
                    result.warnings.append(ValidationIssue(
                        path: pkg.path,
                        severity: .warning,
                        message: "update_for references unknown package: \(updateFor)"
                    ))
                }
            }
            
            // Check requires references
            for requires in pkg.requires {
                if !packageNames.contains(requires) {
                    result.warnings.append(ValidationIssue(
                        path: pkg.path,
                        severity: .warning,
                        message: "requires references unknown package: \(requires)"
                    ))
                }
            }
        }
        
        // Validate manifests
        for manifest in manifests {
            // Check managed_installs references
            for install in manifest.managedInstalls {
                if !packageNames.contains(install) {
                    result.warnings.append(ValidationIssue(
                        path: manifest.path,
                        severity: .warning,
                        message: "managed_installs references unknown package: \(install)"
                    ))
                }
            }
            
            // Check optional_installs references
            for install in manifest.optionalInstalls {
                if !packageNames.contains(install) {
                    result.warnings.append(ValidationIssue(
                        path: manifest.path,
                        severity: .warning,
                        message: "optional_installs references unknown package: \(install)"
                    ))
                }
            }
        }
        
        return result
    }
    
    // MARK: - Linting
    
    public func lint() throws -> [LintIssue] {
        var issues: [LintIssue] = []
        let pkgInfos = try loadAllPkgInfo()
        
        for pkg in pkgInfos {
            // Check naming conventions
            if pkg.name.contains(" ") {
                issues.append(LintIssue(
                    path: pkg.path,
                    rule: "naming",
                    message: "Package name contains spaces: '\(pkg.name)'"
                ))
            }
            
            // Check for missing description
            if pkg.description?.isEmpty ?? true {
                issues.append(LintIssue(
                    path: pkg.path,
                    rule: "documentation",
                    message: "Missing description for package: \(pkg.name)"
                ))
            }
            
            // Check for missing category
            if pkg.category?.isEmpty ?? true {
                issues.append(LintIssue(
                    path: pkg.path,
                    rule: "categorization",
                    message: "Missing category for package: \(pkg.name)"
                ))
            }
            
            // Check for empty catalogs
            if pkg.catalogs.isEmpty {
                issues.append(LintIssue(
                    path: pkg.path,
                    rule: "catalogs",
                    message: "Package has no catalogs assigned: \(pkg.name)"
                ))
            }
            
            // Check for potentially stale packages (no uninstall method)
            if pkg.uninstallMethod?.isEmpty ?? true && pkg.uninstallable != false {
                issues.append(LintIssue(
                    path: pkg.path,
                    rule: "uninstall",
                    message: "Uninstallable package missing uninstall_method: \(pkg.name)"
                ))
            }
        }
        
        return issues
    }
}

// MARK: - Models

struct PkgInfo {
    let path: String
    let name: String
    let version: String
    let displayName: String?
    let description: String?
    let category: String?
    let developer: String?
    let catalogs: [String]
    let installerItemLocation: String?
    let uninstallMethod: String?
    let uninstallable: Bool?
    let updateFor: [String]
    let requires: [String]
    let minimumOSVersion: String?
    let maximumOSVersion: String?
    
    init(from dict: [String: Any], path: String) {
        self.path = path
        self.name = dict["name"] as? String ?? ""
        self.version = dict["version"] as? String ?? ""
        self.displayName = dict["display_name"] as? String
        self.description = dict["description"] as? String
        self.category = dict["category"] as? String
        self.developer = dict["developer"] as? String
        self.catalogs = dict["catalogs"] as? [String] ?? []
        self.installerItemLocation = dict["installer_item_location"] as? String
        self.uninstallMethod = dict["uninstall_method"] as? String
        self.uninstallable = dict["uninstallable"] as? Bool
        self.updateFor = dict["update_for"] as? [String] ?? []
        self.requires = dict["requires"] as? [String] ?? []
        self.minimumOSVersion = dict["minimum_os_version"] as? String
        self.maximumOSVersion = dict["maximum_os_version"] as? String
    }
}

struct CatalogItem {
    let name: String
    let version: String
    
    init?(from dict: [String: Any]) {
        guard let name = dict["name"] as? String,
              let version = dict["version"] as? String else {
            return nil
        }
        self.name = name
        self.version = version
    }
}

struct ManifestFile {
    let path: String
    let catalogs: [String]
    let includedManifests: [String]
    let managedInstalls: [String]
    let managedUninstalls: [String]
    let optionalInstalls: [String]
    
    init(from dict: [String: Any], path: String) {
        self.path = path
        self.catalogs = dict["catalogs"] as? [String] ?? []
        self.includedManifests = dict["included_manifests"] as? [String] ?? []
        self.managedInstalls = dict["managed_installs"] as? [String] ?? []
        self.managedUninstalls = dict["managed_uninstalls"] as? [String] ?? []
        self.optionalInstalls = dict["optional_installs"] as? [String] ?? []
    }
}

// MARK: - Results

public struct ValidationResult {
    public var pkgInfoCount: Int = 0
    public var catalogCount: Int = 0
    public var manifestCount: Int = 0
    public var errors: [ValidationIssue] = []
    public var warnings: [ValidationIssue] = []
    
    public var isValid: Bool { errors.isEmpty }
    
    public init() {}
}

public struct ValidationIssue {
    public let path: String
    public let severity: ValidationSeverity
    public let message: String
    
    public init(path: String, severity: ValidationSeverity, message: String) {
        self.path = path
        self.severity = severity
        self.message = message
    }
}

public enum ValidationSeverity {
    case error
    case warning
}

public struct LintIssue {
    public let path: String
    public let rule: String
    public let message: String
    
    public init(path: String, rule: String, message: String) {
        self.path = path
        self.rule = rule
        self.message = message
    }
}

// MARK: - Errors

public enum PkgInfoError: Error {
    case pathNotFound(String)
    case parseError(String)
}
