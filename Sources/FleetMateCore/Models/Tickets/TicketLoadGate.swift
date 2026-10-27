import Foundation

/// Each refresh owns its result, even when navigation returns to the same ticket.
public struct TicketLoadGate: Sendable {
    public struct Request: Equatable, Sendable {
        public let ticketId: Int
        private let generation: UUID

        fileprivate init(ticketId: Int) {
            self.ticketId = ticketId
            generation = UUID()
        }
    }

    private var current: Request?

    public init() {}

    public mutating func begin(ticketId: Int) -> Request {
        let request = Request(ticketId: ticketId)
        current = request
        return request
    }

    public mutating func invalidate() {
        current = nil
    }

    public func accepts(_ request: Request, selectedTicketId: Int?) -> Bool {
        current == request && selectedTicketId == request.ticketId
    }
}
