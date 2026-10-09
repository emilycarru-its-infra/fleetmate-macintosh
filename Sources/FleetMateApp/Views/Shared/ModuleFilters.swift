import SwiftUI
import FleetMateCore

// MARK: - Deep-linked filters

/// A dashboard widget's handoff: open `tab` with `category` filtered to
/// `value`. `category` is the destination's FilterCategory rawValue.
struct ModuleFilterLink: Equatable {
    let tab: AppTab
    let category: String
    let value: String
}

/// Match a deep-linked value against the category's actual values, tolerating
/// case/punctuation drift ("Non-Compliant" label vs "Noncompliant" value).
func resolveFilterValue(_ incoming: String, in available: [String]?) -> String {
    let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
    return available?.first { norm($0) == norm(incoming) } ?? incoming
}

// MARK: - Ticket Filters

enum TicketFilterCategory: String, FilterCategoryProtocol {
    case status = "Status"
    case priority = "Priority"
    case group = "Group"
    case responsible = "Responsible"
    case form = "Form"
    case classification = "Classification"
    case type = "Type"
    case timePeriod = "Time Period"
    var id: String { rawValue }
}

extension FilterState where Category == TicketFilterCategory {
    func buildFromTickets(_ tickets: [TdxTicket]) {
        func extract(_ keyPath: (TdxTicket) -> String?) -> [String] {
            Array(Set(tickets.compactMap(keyPath).filter { !$0.isEmpty })).sorted()
        }
        availableValues[.status] = extract { $0.statusName }
        availableValues[.priority] = extract { $0.priorityName }
        availableValues[.group] = extract { $0.responsibleGroupName }
        // Unassigned is a real state to filter on, not the absence of one —
        // it's how you find the tickets nobody has picked up yet.
        var responsibles = extract { $0.responsibleFullName }
        if tickets.contains(where: { $0.responsibleFullName?.isEmpty != false }) {
            responsibles.append("Unassigned")
        }
        availableValues[.responsible] = responsibles
        availableValues[.form] = extract { $0.formName }
        availableValues[.classification] = extract { $0.classificationName }
        availableValues[.type] = extract { $0.typeName }
        availableValues[.timePeriod] = ["This Term", "Last Term", "Today", "This Week", "This Month", "Include Closed"]
    }

    func matches(_ ticket: TdxTicket) -> Bool {
        matches(ticket, ignoring: nil)
    }

    /// Matches every selection except `ignored`'s, so a widget can count the
    /// values of its own category with the other filters applied and its own
    /// values can still be added to.
    func matches(_ ticket: TdxTicket, ignoring ignored: TicketFilterCategory?) -> Bool {
        for (category, selected) in selectedValues where !selected.isEmpty && category != ignored {
            let value: String?
            switch category {
            case .status:         value = ticket.statusName
            case .priority:       value = ticket.priorityName
            case .group:          value = ticket.responsibleGroupName
            case .responsible:
                value = ticket.responsibleFullName?.isEmpty == false
                    ? ticket.responsibleFullName : "Unassigned"
            case .form:           value = ticket.formName
            case .classification: value = ticket.classificationName
            case .type:           value = ticket.typeName
            case .timePeriod:     continue // handled externally by date range logic
            }
            if let v = value, !selected.contains(v) { return false }
            if value == nil { return false }
        }
        return true
    }
}

// MARK: - Device Filters

typealias DeviceFilterCategory = DeviceFacet
extension DeviceFacet: FilterCategoryProtocol {}

extension FilterState where Category == DeviceFacet {
    /// Offer only values the rows carry, with how many rows carry each. The
    /// Apple organization's and Autopilot's categories are hidden when the
    /// source is absent.
    func buildFromRows(_ rows: [DeviceListRow], hasAppleOrg: Bool, hasAutopilot: Bool = false) {
        hiddenCategories = DeviceFacet.hidden(hasAppleOrg: hasAppleOrg, hasAutopilot: hasAutopilot)
        for facet in DeviceFacet.allCases {
            var counts: [String: Int] = [:]
            for row in rows {
                for value in row.values(for: facet) { counts[value, default: 0] += 1 }
            }
            availableValues[facet] = counts.keys.sorted()
            valueCounts[facet] = counts
        }
        // With every source in agreement there is nothing to narrow by.
        if Set(availableValues[.discrepancy] ?? []).subtracting([DeviceDiscrepancy.none]).isEmpty {
            hiddenCategories.insert(.discrepancy)
        }
        if hiddenCategories.contains(selectedCategory),
           let first = DeviceFacet.allCases.first(where: { !hiddenCategories.contains($0) }) {
            selectedCategory = first
        }
    }

    func matches(_ row: DeviceListRow) -> Bool {
        for (facet, selected) in selectedValues where !selected.isEmpty && !hiddenCategories.contains(facet) {
            if selected.isDisjoint(with: row.values(for: facet)) { return false }
        }
        return true
    }
}

// MARK: - Project/Task Filters

enum TaskFilterCategory: String, FilterCategoryProtocol {
    case area = "Area"
    case iteration = "Iteration"
    case type = "Type"
    case priority = "Priority"
    case assignee = "Assignee"
    // Provider stays last: with the backend toolbar dropdown gone, it is the
    // least-reached-for narrowing and sits at the bottom of the panel.
    case provider = "Provider"
    var id: String { rawValue }
}

extension FilterState where Category == TaskFilterCategory {
    func buildFromTasks(_ tasks: [UnifiedTask]) {
        func extract(_ keyPath: (UnifiedTask) -> String?) -> [String] {
            Array(Set(tasks.compactMap(keyPath).filter { !$0.isEmpty })).sorted()
        }
        availableValues[.provider] = extract { $0.provider }
        availableValues[.area] = extract { $0.metadata["areaPath"] }
        availableValues[.iteration] = extract { $0.metadata["iterationPath"] }
        availableValues[.type] = extract { $0.metadata["workItemType"] }
        availableValues[.priority] = extract {
            if let p = $0.priority { return "P\(p)" }
            return nil
        }
        availableValues[.assignee] = extract { $0.assignees.first }
    }

    func matches(_ task: UnifiedTask) -> Bool {
        for (category, selected) in selectedValues where !selected.isEmpty {
            let value: String?
            switch category {
            case .provider:  value = task.provider
            case .area:      value = task.metadata["areaPath"]
            case .iteration: value = task.metadata["iterationPath"]
            case .type:      value = task.metadata["workItemType"]
            case .priority:
                if let p = task.priority { value = "P\(p)" } else { value = nil }
            case .assignee:  value = task.assignees.first
            }
            if let v = value, !selected.contains(v) { return false }
            if value == nil { return false }
        }
        return true
    }
}
