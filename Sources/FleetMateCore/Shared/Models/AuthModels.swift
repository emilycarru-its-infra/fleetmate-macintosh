import Foundation

// MARK: - Auth System Categories

/// Top-level grouping of connected systems, matching the config JSON structure.
public enum AuthCategory: String, CaseIterable, Codable, Sendable {
    case devices
    case inventory
    case tickets
    case projects
    case identity
    
    public var displayName: String {
        switch self {
        case .devices:    return "Devices"
        case .inventory: return "Inventory"
        case .tickets:  return "Tickets"
        case .projects: return "Projects"
        case .identity: return "Identity"
        }
    }
    
    public var icon: String {
        switch self {
        case .devices:    return "laptopcomputer"
        case .inventory: return "shippingbox"
        case .tickets:  return "ticket"
        case .projects: return "rectangle.split.3x1"
        case .identity: return "person.2"
        }
    }
}

/// Known system identifiers.
public enum AuthSystemId: String, CaseIterable, Codable, Sendable {
    case intune
    case graph
    case snipe
    case tdx
    case devops
    case github
    case gitea
    case entra
    
    public var displayName: String {
        switch self {
        case .intune:  return "Intune"
        case .graph:   return "Microsoft Graph"
        case .snipe:   return "Snipe-IT"
        case .tdx:     return "TeamDynamix"
        case .devops:  return "DevOps"
        case .github:  return "GitHub"
        case .gitea:   return "Gitea"
        case .entra:   return "Entra ID"
        }
    }
    
    public var icon: String {
        switch self {
        case .intune:  return "laptopcomputer"
        case .graph:   return "network"
        case .snipe:   return "shippingbox"
        case .tdx:     return "ticket"
        case .devops:  return "chevron.left.forwardslash.chevron.right"
        case .github:  return "chevron.left.forwardslash.chevron.right"
        case .gitea:   return "arrow.triangle.branch"
        case .entra:   return "person.badge.shield.checkmark"
        }
    }
    
    /// Which tab category this system belongs to.
    public var category: AuthCategory {
        switch self {
        case .intune, .graph: return .devices
        case .snipe:          return .inventory
        case .tdx:            return .tickets
        case .devops, .github, .gitea: return .projects
        case .entra:          return .identity
        }
    }
}

// MARK: - Auth Token State

public enum AuthTokenState: Sendable {
    case notConfigured
    case configured        // Has credentials but not yet validated
    case authenticating    // Currently checking
    case valid(user: String?, expiry: Date?)
    case expired
    case failed(message: String)
    case servicePrincipal(name: String) // Special: logged in as SP
    
    public var isHealthy: Bool {
        switch self {
        case .valid: return true
        default: return false
        }
    }
    
    public var statusLabel: String {
        switch self {
        case .notConfigured:        return "Not Configured"
        case .configured:           return "Configured"
        case .authenticating:       return "Authenticating…"
        case .valid:                return "Valid"
        case .expired:              return "Expired"
        case .failed(let msg):      return "Failed: \(msg)"
        case .servicePrincipal:     return "Service Principal"
        }
    }
    
    public var statusColor: String {
        switch self {
        case .valid:             return "green"
        case .configured:        return "yellow"
        case .authenticating:    return "blue"
        case .expired:           return "orange"
        case .failed:            return "red"
        case .servicePrincipal:  return "orange"
        case .notConfigured:     return "gray"
        }
    }
}

// MARK: - Per-System Status

/// Tracks auth state for a single connected system.
public struct AuthSystemStatus: Sendable {
    public let systemId: AuthSystemId
    public var state: AuthTokenState
    public var user: String?
    public var lastChecked: Date?
    
    public init(systemId: AuthSystemId, state: AuthTokenState = .notConfigured) {
        self.systemId = systemId
        self.state = state
    }
}
