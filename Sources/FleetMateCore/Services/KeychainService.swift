import Foundation
import Security

/// Service for storing and retrieving secrets from macOS Keychain.
/// Secrets are populated by scripts/setup-secrets.sh from Azure Key Vault.
/// Replaces Windows Registry-based credential storage.
public class KeychainService {
    
    /// The service name used for all FleetMate keychain items.
    /// Must match the service name in scripts/setup-secrets.sh
    public static let serviceName = "com.github.fleetmate-qa"
    
    /// Keychain keys for all FleetMate credentials
    public enum Key: String, CaseIterable {
        // ReportMate
        case reportMateUrl = "ReportMateUrl"
        case reportMatePassphrase = "ReportMatePassphrase"
        
        // Snipe-IT
        case snipeUrl = "SnipeUrl"
        case snipeApiKey = "SnipeApiKey"
        
        // Microsoft Graph
        case graphTenantId = "GraphTenantId"
        case graphClientId = "GraphClientId"
        case graphClientSecret = "GraphClientSecret"
        
        // Azure DevOps
        case devopsOrganization = "DevOpsOrganization"
        case devopsProject = "DevOpsProject"
        case devopsPat = "DevOpsPat"
        
        // TeamDynamix
        case tdxBaseUrl = "TdxBaseUrl"
        case tdxAppId = "TdxAppId"
        case tdxUsername = "TdxUsername"
        case tdxPassword = "TdxPassword"
        case tdxBeid = "TdxBeid"
        case tdxWebServicesKey = "TdxWebServicesKey"
        
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
        
        // Delete any existing item first
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainService.serviceName,
            kSecAttrAccount: key.rawValue
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add new item
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainService.serviceName,
            kSecAttrAccount: key.rawValue,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        
        if status != errSecSuccess {
            throw KeychainError.saveFailed(status: status, key: key.rawValue)
        }
    }
    
    /// Retrieve a value from the keychain
    public func get(_ key: Key) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: KeychainService.serviceName,
            kSecAttrAccount: key.rawValue,
            kSecReturnData: true,
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
    
    /// Import credentials from environment variables
    public func importFromEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        
        let mapping: [(String, Key)] = [
            ("REPORTMATE_URL", .reportMateUrl),
            ("REPORTMATE_PASSPHRASE", .reportMatePassphrase),
            ("SNIPE_URL", .snipeUrl),
            ("SNIPE_API_KEY", .snipeApiKey),
            ("GRAPH_TENANT_ID", .graphTenantId),
            ("GRAPH_CLIENT_ID", .graphClientId),
            ("GRAPH_CLIENT_SECRET", .graphClientSecret),
            ("DEVOPS_ORGANIZATION", .devopsOrganization),
            ("DEVOPS_PROJECT", .devopsProject),
            ("DEVOPS_PAT", .devopsPat),
            ("AZURE_DEVOPS_PAT", .devopsPat),
            ("TDX_BASE_URL", .tdxBaseUrl),
            ("TDX_APP_ID", .tdxAppId),
            ("TDX_USERNAME", .tdxUsername),
            ("TDX_PASSWORD", .tdxPassword),
            ("TDX_BEID", .tdxBeid),
            ("TDX_WEB_SERVICES_KEY", .tdxWebServicesKey),
            ("SECURE_SHELL_PRIVATE_KEY", .sshPrivateKey),
            ("SSH_KEY_PATH", .sshKeyPath),
            ("SSH_USER", .sshDefaultUsername),
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
