import Foundation
import Security

/// Service for storing and retrieving secrets from macOS Keychain.
/// Secrets are populated by scripts/setup-secrets.sh from Azure Key Vault.
/// Replaces Windows Registry-based credential storage.
public class KeychainService {
    
    /// The service name used for all FleetMate keychain items.
    /// Must match the service name in scripts/setup-secrets.sh
    public static let serviceName = "ca.ecuad.macadmin.fleetmate"
    
    /// Keychain keys for all FleetMate credentials
    public enum Key: String, CaseIterable {
        // ReportMate
        case reportMateUrl = "ReportMateUrl"
        case reportMatePassphrase = "ReportMatePassphrase"
        
        // Snipe-IT
        case snipeUrl = "SnipeUrl"
        case snipeApiKey = "SnipeApiKey"
        
        // Microsoft Graph — shared tenant
        case graphTenantId = "GraphTenantId"
        // Legacy single service principal
        case graphClientId = "GraphClientId"
        case graphClientSecret = "GraphClientSecret"
        // Devices (Intune) service principal
        case devicesGraphId = "DevicesGraphId"
        case devicesGraphSecret = "DevicesGraphSecret"
        // Systems (Entra) service principal
        case systemsGraphId = "SystemsGraphId"
        case systemsGraphSecret = "SystemsGraphSecret"

        // Azure DevOps
        case devopsOrganization = "DevOpsOrganization"
        case devopsProject = "DevOpsProject"
        case devopsClientId = "DevOpsClientId"
        case devopsTenantId = "DevOpsTenantId"
        // NO PAT — Azure DevOps uses SSO only

        // TeamDynamix
        case tdxBaseUrl = "TdxBaseUrl"
        case tdxAppId = "TdxAppId"
        case tdxTicketingAppId = "TdxTicketingAppId"
        case tdxAssetsAppId = "TdxAssetsAppId"
        case tdxUsername = "TdxUsername"
        case tdxPassword = "TdxPassword"
        case tdxBeid = "TdxBeid"
        case tdxWebServicesKey = "TdxWebServicesKey"
        case tdxResponsibleGroupId = "TdxResponsibleGroupId"
        
        // SecureShell
        case sshPrivateKey = "SshPrivateKey"
        case sshKeyPath = "SshKeyPath"
        case sshDefaultUsername = "SshDefaultUsername"
        case sshKeyVaultName = "SshKeyVaultName"
    }
    
    /// Shared singleton instance
    public static let shared = KeychainService()
    
    private init() {}
    
    // MARK: - Public API
    
    /// Save a value to the keychain
    public func save(_ value: String, for key: Key) throws {
        let data = value.data(using: .utf8)!

        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainService.serviceName,
            kSecAttrAccount: key.rawValue
        ]

        // Delete any existing item
        let delStatus = SecItemDelete(baseQuery as CFDictionary)
        if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
            dbg.warn("[Keychain] Delete for \(key.rawValue) returned \(delStatus)", category: "config")
        }

        // Add new item
        var addQuery = baseQuery
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        dbg.info("[Keychain] \(key.rawValue): del=\(delStatus) add=\(addStatus) len=\(data.count)", category: "config")

        if addStatus == errSecDuplicateItem {
            // Item exists but we couldn't delete it (different ACL?) — try update instead
            let updateAttrs: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus != errSecSuccess {
                dbg.error("[Keychain] Update fallback FAILED for \(key.rawValue): \(updateStatus)", category: "config")
                throw KeychainError.saveFailed(status: updateStatus, key: key.rawValue)
            }
        } else if addStatus != errSecSuccess {
            dbg.error("[Keychain] Add FAILED for \(key.rawValue): \(addStatus)", category: "config")
            throw KeychainError.saveFailed(status: addStatus, key: key.rawValue)
        }
    }
    
    /// Retrieve a value from the keychain
    public func get(_ key: Key) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainService.serviceName,
            kSecAttrAccount: key.rawValue,
            kSecReturnData: true as CFBoolean,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return value
    }
    
    /// Delete a value from the keychain
    public func delete(_ key: Key) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainService.serviceName,
            kSecAttrAccount: key.rawValue
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status: status, key: key.rawValue)
        }
    }
    
    /// Check if a key exists in the keychain
    public func exists(_ key: Key) -> Bool {
        return get(key) != nil
    }
    
    /// Delete all FleetMate credentials from keychain
    public func clearAll() throws {
        for key in Key.allCases {
            try delete(key)
        }
    }
    
    /// Check if credentials are configured
    public var hasReportMateCredentials: Bool {
        return exists(.reportMateUrl) && exists(.reportMatePassphrase)
    }
    
    public var hasSnipeCredentials: Bool {
        return exists(.snipeUrl) && exists(.snipeApiKey)
    }
    
    public var hasGraphCredentials: Bool {
        return exists(.graphTenantId) && exists(.graphClientId)
    }
    
    public var hasDevOpsCredentials: Bool {
        return exists(.devopsOrganization) && exists(.devopsProject)
    }
    
    public var hasTdxCredentials: Bool {
        return exists(.tdxBaseUrl) && exists(.tdxAppId)
    }
    
    /// Get all stored keys (for status display)
    public func getStoredKeys() -> [Key] {
        return Key.allCases.filter { exists($0) }
    }
    
    /// Seed Keychain from environment variables. Intended for CI bootstrap only.
    public func importFromEnvironment() throws {
        let env = ProcessInfo.processInfo.environment

        let mapping: [(String, Key)] = [
            ("REPORTMATE_URL",          .reportMateUrl),
            ("REPORTMATE_PASSPHRASE",   .reportMatePassphrase),
            ("SNIPE_URL",               .snipeUrl),
            ("SNIPE_API_KEY",           .snipeApiKey),
            ("GRAPH_TENANT_ID",         .graphTenantId),
            ("GRAPH_CLIENT_ID",         .graphClientId),
            ("GRAPH_CLIENT_SECRET",     .graphClientSecret),
            ("DEVICES_GRAPH_ID",        .devicesGraphId),
            ("DEVICES_GRAPH_SECRET",    .devicesGraphSecret),
            ("SYSTEMS_GRAPH_ID",        .systemsGraphId),
            ("SYSTEMS_GRAPH_SECRET",    .systemsGraphSecret),
            ("DEVOPS_ORGANIZATION",     .devopsOrganization),
            ("DEVOPS_PROJECT",          .devopsProject),
            ("DEVOPS_CLIENT_ID",        .devopsClientId),
            ("DEVOPS_TENANT_ID",        .devopsTenantId),
            ("TDX_BASE_URL",            .tdxBaseUrl),
            ("TDX_APP_ID",              .tdxAppId),
            ("TDX_TICKETING_APP_ID",    .tdxTicketingAppId),
            ("TDX_ASSETS_APP_ID",       .tdxAssetsAppId),
            ("TDX_USERNAME",            .tdxUsername),
            ("TDX_PASSWORD",            .tdxPassword),
            ("TDX_BEID",                .tdxBeid),
            ("TDX_WEB_SERVICES_KEY",    .tdxWebServicesKey),
            ("TDX_RESPONSIBLE_GROUP_ID",.tdxResponsibleGroupId),
            ("SSH_KEY_PATH",            .sshKeyPath),
            ("SSH_USER",                .sshDefaultUsername),
        ]

        for (envVar, key) in mapping {
            if let value = env[envVar], !value.isEmpty {
                try save(value, for: key)
            }
        }
    }
}

// MARK: - Errors

public enum KeychainError: LocalizedError {
    case saveFailed(status: OSStatus, key: String)
    case deleteFailed(status: OSStatus, key: String)
    
    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status, let key):
            return "Failed to save '\(key)' to Keychain: OSStatus \(status)"
        case .deleteFailed(let status, let key):
            return "Failed to delete '\(key)' from Keychain: OSStatus \(status)"
        }
    }
}
