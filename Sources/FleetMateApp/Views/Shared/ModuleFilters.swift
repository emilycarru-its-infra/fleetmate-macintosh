import SwiftUI
import FleetMateCore

// MARK: - Ticket Filters

enum TicketFilterCategory: String, FilterCategoryProtocol {
    case status = "Status"
    case priority = "Priority"
    case group = "Group"
    case responsible = "Responsible"
    case form = "Form"
    case classification = "Classification"
    case type = "Type"
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
        availableValues[.responsible] = extract { $0.responsibleFullName }
        availableValues[.form] = extract { $0.formName }
        availableValues[.classification] = extract { $0.classificationName }
        availableValues[.type] = extract { $0.typeName }
    }

    func matches(_ ticket: TdxTicket) -> Bool {
        for (category, selected) in selectedValues where !selected.isEmpty {
            let value: String?
            switch category {
            case .status:         value = ticket.statusName
            case .priority:       value = ticket.priorityName
            case .group:          value = ticket.responsibleGroupName
            case .responsible:    value = ticket.responsibleFullName
            case .form:           value = ticket.formName
            case .classification: value = ticket.classificationName
            case .type:           value = ticket.typeName
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
