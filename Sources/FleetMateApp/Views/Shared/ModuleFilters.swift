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
        for (category, selected) in selectedValues where !selected.isEmpty {
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

enum DeviceFilterCategory: String, FilterCategoryProtocol {
    case platform = "Platform"
    case compliance = "Compliance"
    case manufacturer = "Manufacturer"
    case model = "Model"
    case ownership = "Ownership"
    var id: String { rawValue }
}

extension FilterState where Category == DeviceFilterCategory {
    func buildFromDevices(_ devices: [IntuneDevice]) {
        func extract(_ keyPath: (IntuneDevice) -> String?) -> [String] {
            Array(Set(devices.compactMap(keyPath).filter { !$0.isEmpty })).sorted()
        }
        availableValues[.platform] = extract { $0.operatingSystem }
        availableValues[.compliance] = extract { $0.complianceState?.capitalized }
        availableValues[.manufacturer] = extract { $0.manufacturer }
        availableValues[.model] = extract { $0.model }
        availableValues[.ownership] = extract { $0.managedDeviceOwnerType }
    }

    func matches(_ device: IntuneDevice) -> Bool {
        for (category, selected) in selectedValues where !selected.isEmpty {
            let value: String?
            switch category {
            case .platform:     value = device.operatingSystem
            case .compliance:   value = device.complianceState?.capitalized
            case .manufacturer: value = device.manufacturer
            case .model:        value = device.model
            case .ownership:    value = device.managedDeviceOwnerType
            }
            if let v = value, !selected.contains(v) { return false }
            if value == nil { return false }
        }
        return true
    }
}

// MARK: - Project/Task Filters

enum TaskFilterCategory: String, FilterCategoryProtocol {
    case provider = "Provider"
    case area = "Area"
    case iteration = "Iteration"
    case type = "Type"
    case priority = "Priority"
    case assignee = "Assignee"
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
