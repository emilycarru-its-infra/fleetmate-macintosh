import Foundation

/// A ticket plus the tickets that name it as their parent.
public struct TicketNode: Identifiable, Hashable, Sendable {
    public let ticket: TdxTicket
    public let children: [TicketNode]

    public var id: Int { ticket.id ?? -1 }
    public var hasChildren: Bool { !children.isEmpty }

    /// Children, grandchildren, and so on.
    public var descendantCount: Int {
        children.count + children.reduce(0) { $0 + $1.descendantCount }
    }
}

/// One line of an outline: a ticket, how deep it sits, and whether it can fold.
public struct TicketOutlineRow: Identifiable, Hashable, Sendable {
    public let ticket: TdxTicket
    public let depth: Int
    public let childCount: Int
    public let isExpanded: Bool

    public var id: Int { ticket.id ?? -1 }
    public var hasChildren: Bool { childCount > 0 }
}

/// Builds the parent/child outline the Tickets tab renders.
///
/// TDX gives every ticket a `ParentID` but no way to search by it, so the tree
/// is assembled from whatever tickets are already loaded rather than fetched.
public enum TicketHierarchy {

    /// Group `tickets` into roots and their descendants, preserving input order.
    ///
    /// A ticket only becomes a child when its parent is also in `tickets`. A
    /// ticket whose parent was filtered out (wrong status, outside the date
    /// range, different group) therefore stays a root instead of vanishing from
    /// the list along with the parent that no longer appears.
    public static func build(from tickets: [TdxTicket]) -> [TicketNode] {
        let present = Set(tickets.compactMap(\.id))
        var childrenByParent: [Int: [TdxTicket]] = [:]
        var roots: [TdxTicket] = []

        for ticket in tickets {
            if let parentId = ticket.parentTicketId, present.contains(parentId), parentId != ticket.id {
                childrenByParent[parentId, default: []].append(ticket)
            } else {
                roots.append(ticket)
            }
        }

        return roots.map { node(for: $0, childrenByParent: childrenByParent, ancestors: []) }
    }

    private static func node(
        for ticket: TdxTicket,
        childrenByParent: [Int: [TdxTicket]],
        ancestors: Set<Int>
    ) -> TicketNode {
        guard let id = ticket.id, !ancestors.contains(id) else {
            // A parent chain that loops back on itself would recurse forever.
            return TicketNode(ticket: ticket, children: [])
        }
        let children = (childrenByParent[id] ?? []).map {
            node(for: $0, childrenByParent: childrenByParent, ancestors: ancestors.union([id]))
        }
        return TicketNode(ticket: ticket, children: children)
    }

    /// Flatten an outline to rows, hiding the subtrees of collapsed parents.
    public static func flatten(_ nodes: [TicketNode], collapsed: Set<Int>) -> [TicketOutlineRow] {
        var rows: [TicketOutlineRow] = []
        appendRows(nodes, depth: 0, collapsed: collapsed, into: &rows)
        return rows
    }

    private static func appendRows(
        _ nodes: [TicketNode],
        depth: Int,
        collapsed: Set<Int>,
        into rows: inout [TicketOutlineRow]
    ) {
        for node in nodes {
            let expanded = !collapsed.contains(node.id)
            rows.append(TicketOutlineRow(
                ticket: node.ticket,
                depth: depth,
                childCount: node.children.count,
                isExpanded: expanded
            ))
            if expanded && node.hasChildren {
                appendRows(node.children, depth: depth + 1, collapsed: collapsed, into: &rows)
            }
        }
    }

    /// Every ticket that something else nests under, for expand-all /
    /// collapse-all.
    ///
    /// Answered straight from the ticket list rather than by walking a built
    /// tree — the toolbar asks this on each render, and it must not cost a
    /// second sort and rebuild of the whole outline.
    public static func foldableIds(in tickets: [TdxTicket]) -> Set<Int> {
        let present = Set(tickets.compactMap(\.id))
        return Set(tickets.compactMap { ticket in
            guard let parentId = ticket.parentTicketId,
                  present.contains(parentId),
                  parentId != ticket.id else { return nil }
            return parentId
        })
    }
}
