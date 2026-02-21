import Foundation

// MARK: - TDX Ticket (Unified)

/// TDX ticket conforming to UnifiedTicket protocol.
public struct TdxUnifiedTicket: UnifiedTicket, Sendable {
    public let id: String
    public let provider: String = "tdx"
    public let ticketNumber: String
    public let title: String
    public let description: String?
    public let status: String?
    public let priority: String?
    public let type: String?
    public let requestor: String?
    public let assignedTo: String?
    public let responsibleGroup: String?
    public let createdDate: Date?
    public let modifiedDate: Date?
    public let dueDate: Date?
    public let closedDate: Date?
    public let externalUrl: String?
    
    /// Original TDX ticket for full access to all fields.
    public let rawTicket: TdxTicket
    
    public init(from ticket: TdxTicket, baseUrl: String?) {
        let ticketId = ticket.id ?? 0
        self.id = String(ticketId)
        self.ticketNumber = String(ticketId)
        self.title = ticket.title ?? "Untitled"
        self.description = ticket.description
        self.status = ticket.statusName
        self.priority = ticket.priorityName
        self.type = ticket.typeName
        self.requestor = ticket.requestorName
        self.assignedTo = ticket.responsibleFullName
        self.responsibleGroup = ticket.accountName
        self.createdDate = Self.parseDate(ticket.createdDate)
        self.modifiedDate = Self.parseDate(ticket.modifiedDate)
        self.dueDate = Self.parseDate(ticket.respondByDate)
        self.closedDate = nil // TDX doesn't expose closed date directly
        
        if let baseUrl = baseUrl, let uri = ticket.uri {
            self.externalUrl = "\(baseUrl)\(uri)"
        } else {
            self.externalUrl = nil
        }
        
        self.rawTicket = ticket
    }
    
    private static func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}

// MARK: - TDX Ticket Provider

/// TeamDynamix ticket provider implementing TicketProvider protocol.
public actor TdxTicketProvider: TicketProvider {
    public typealias TicketType = TdxUnifiedTicket
    
    private let service: TdxService
    private let config: FleetMateConfig
    private var authenticated = false
    
    public nonisolated let providerId: String = "tdx"
    public nonisolated let providerName: String = "TeamDynamix"
    
    public var isEnabled: Bool {
        config.isTdxConfigured
    }
    
    public init(config: FleetMateConfig) {
        self.config = config
        self.service = TdxService(config: config)
    }
    
    public func authenticate() async throws -> Bool {
        do {
            _ = try await service.searchTickets(search: TicketSearchRequest(maxResults: 1))
            authenticated = true
            return true
        } catch {
            authenticated = false
            throw ProviderError.unauthorized
        }
    }
    
    public func listTickets(filter: TicketFilter?) async throws -> [TdxUnifiedTicket] {
        var request = TicketSearchRequest()
        
        if let filter = filter {
            request.searchText = filter.searchText
            
            if let status = filter.status {
                // Would need to map status name to IDs - for now use as search text
                request.searchText = [request.searchText, status].compactMap { $0 }.joined(separator: " ")
            }
            
            if let responsibleGroupId = filter.responsibleGroupId {
                request.responsibleGroupIds = [responsibleGroupId]
            } else if let configGroupId = config.tdxResponsibleGroupId {
                request.responsibleGroupIds = [configGroupId]
            }
            
            if let assignedTo = filter.assignedTo {
                request.responsibleUids = [assignedTo]
            }
            
            if let requestor = filter.requestor {
                request.requestorUids = [requestor]
            }
            
            request.maxResults = filter.limit ?? 500
        } else {
            // Default: use configured group if available
            if let configGroupId = config.tdxResponsibleGroupId {
                request.responsibleGroupIds = [configGroupId]
            }
            request.maxResults = 500
        }
        
        let tickets = try await service.searchTickets(search: request)
        return tickets.map { TdxUnifiedTicket(from: $0, baseUrl: config.tdxBaseUrl) }
    }
    
    public func getTicket(ticketId: String) async throws -> TdxUnifiedTicket? {
        guard let id = Int(ticketId) else {
            throw ProviderError.invalidRequest("Invalid ticket ID: \(ticketId)")
        }
        
        guard let ticket = try await service.getTicket(id: id) else {
            return nil
        }
        
        return TdxUnifiedTicket(from: ticket, baseUrl: config.tdxBaseUrl)
    }
    
    public func searchTickets(query: String, limit: Int) async throws -> [TdxUnifiedTicket] {
        var request = TicketSearchRequest()
        request.searchText = query
        request.maxResults = limit
        
        if let configGroupId = config.tdxResponsibleGroupId {
            request.responsibleGroupIds = [configGroupId]
        }
        
        let tickets = try await service.searchTickets(search: request)
        return tickets.map { TdxUnifiedTicket(from: $0, baseUrl: config.tdxBaseUrl) }
    }
    
    public func createTicket(request: UnifiedCreateTicketRequest) async throws -> TdxUnifiedTicket {
        // TDX ticket creation requires specific API that TdxService may not have
        // This would need to be implemented in TdxService
        throw ProviderError.apiError("Ticket creation not yet implemented for TDX")
    }
    
    public func updateTicket(ticketId: String, request: UnifiedUpdateTicketRequest) async throws -> TdxUnifiedTicket {
        // TDX ticket update requires specific API
        throw ProviderError.apiError("Ticket update not yet implemented for TDX")
    }
    
    public func addComment(ticketId: String, comment: String, isPrivate: Bool) async throws {
        // TDX feed entry API not currently exposed in TdxService
        throw ProviderError.apiError("Add comment not yet implemented for TDX")
    }
    
    public func listStatuses() async throws -> [TicketStatus] {
        // TDX would need an API call to get statuses
        // For now return common statuses
        return [
            TicketStatus(id: "1", name: "New", isDefault: true, isClosed: false),
            TicketStatus(id: "2", name: "In Progress", isDefault: false, isClosed: false),
            TicketStatus(id: "3", name: "On Hold", isDefault: false, isClosed: false),
            TicketStatus(id: "4", name: "Resolved", isDefault: false, isClosed: true),
            TicketStatus(id: "5", name: "Closed", isDefault: false, isClosed: true)
        ]
    }
    
    public func listCategories() async throws -> [TicketCategory] {
        // TDX would need an API call to get types
        return []
    }
}
