import SwiftUI
import FleetMateCore

/// Detail panel showing comprehensive device information from Intune/Graph API.
/// Displayed when a single device is selected in the device list.
struct DeviceDetailView: View {
    @EnvironmentObject var appState: AppState
    let device: IntuneDevice
    
    @State private var groupMemberships: [DeviceGroupMembership] = []
    @State private var detectedApps: [DetectedApp] = []
    @State private var compliancePolicies: [DeviceCompliancePolicyState] = []
    @State private var isLoadingGroups = false
    @State private var isLoadingApps = false
    @State private var isLoadingCompliance = false
    @State private var errorMessage: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                deviceHeader
                
                Divider()
                
                // Sections
                VStack(alignment: .leading, spacing: 16) {
                    deviceSummarySection
                    Divider()
                    groupMembershipSection
                    Divider()
                    enrollmentSection
                    Divider()
                    hardwareSection
                    Divider()
                    complianceSection
                    Divider()
                    managedAppsSection
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .task(id: device.id) {
            await loadDeviceDetails()
        }
    }
    
    // MARK: - Header
    
    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: deviceIcon)
                    .appFont(.title)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.deviceName ?? "Unknown Device")
                        .appFont(.title2)
                        .fontWeight(.bold)
                        .textSelection(.enabled)
                    Text(device.managedDeviceName ?? device.serialNumber ?? "")
                        .appFont(.subheadline)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                ComplianceBadge(state: device.complianceState)
            }
            
            if let error = errorMessage {
                Text(error)
                    .appFont(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
    }
    
    // MARK: - Device Summary
    
    private var deviceSummarySection: some View {
        DetailSection(title: "Summary", icon: "info.circle") {
            DeviceDetailRow(label: "Device Name", value: device.deviceName)
            DeviceDetailRow(label: "Management Name", value: device.managedDeviceName)
            DeviceDetailRow(label: "Ownership", value: ownershipDisplay)
            DeviceDetailRow(label: "Manufacturer", value: device.manufacturer)
            DeviceDetailRow(label: "Model", value: device.model)
            DeviceDetailRow(label: "OS", value: osDisplay)
            DeviceDetailRow(label: "Last Check-in", value: formatDate(device.lastSyncDateTime))
            DeviceDetailRow(label: "Primary User", value: device.userDisplayName ?? device.userPrincipalName)
        }
    }
    
    // MARK: - IDs & Enrollment
    
    private var enrollmentSection: some View {
        DetailSection(title: "Enrollment & Identity", icon: "person.badge.key") {
            DeviceDetailRow(label: "Intune Device ID", value: device.id, monospaced: true)
            DeviceDetailRow(label: "Entra Device ID", value: device.azureADDeviceId, monospaced: true)
            DeviceDetailRow(label: "Enrollment Type", value: enrollmentTypeDisplay)
            DeviceDetailRow(label: "Enrollment Profile", value: device.enrollmentProfileName)
            DeviceDetailRow(label: "User Approved Enrollment", value: device.isSupervised == true ? "Yes" : (device.isSupervised == false ? "No" : nil))
            DeviceDetailRow(label: "Enrolled", value: formatDate(device.enrolledDateTime))
            DeviceDetailRow(label: "Registration State", value: device.deviceRegistrationState)
            DeviceDetailRow(label: "Management Agent", value: device.managementAgent)
            DeviceDetailRow(label: "Join Type", value: device.joinType)
        }
    }
    
    // MARK: - Hardware
    
    private var hardwareSection: some View {
        DetailSection(title: "Hardware", icon: "cpu") {
            DeviceDetailRow(label: "Serial Number", value: device.serialNumber, monospaced: true)
            DeviceDetailRow(label: "SKU Family", value: device.skuFamily)
            if let total = device.totalStorageSpaceInBytes, total > 0 {
                DeviceDetailRow(label: "Total Storage", value: formatBytes(total))
            }
            if let free = device.freeStorageSpaceInBytes, free > 0 {
                DeviceDetailRow(label: "Free Storage", value: formatBytes(free))
            }
            if let mem = device.physicalMemoryInBytes, mem > 0 {
                DeviceDetailRow(label: "Physical Memory", value: formatBytes(mem))
            }
            DeviceDetailRow(label: "Wi-Fi MAC", value: device.wiFiMacAddress, monospaced: true)
            DeviceDetailRow(label: "Ethernet MAC", value: device.ethernetMacAddress, monospaced: true)
            if device.imei != nil || device.meid != nil {
                DeviceDetailRow(label: "IMEI", value: device.imei, monospaced: true)
                DeviceDetailRow(label: "MEID", value: device.meid, monospaced: true)
                DeviceDetailRow(label: "Phone Number", value: device.phoneNumber)
                DeviceDetailRow(label: "Carrier", value: device.subscriberCarrier)
            }
        }
    }
    
    // MARK: - Compliance / Conditional Access
    
    private var complianceSection: some View {
        DetailSection(title: "Compliance & Conditional Access", icon: "shield.checkered") {
            DeviceDetailRow(label: "Compliance State", value: device.complianceState)
            DeviceDetailRow(label: "Management State", value: device.managementState)
            DeviceDetailRow(label: "Azure AD Registered", value: device.azureADRegistered == true ? "Yes" : (device.azureADRegistered == false ? "No" : nil))
            DeviceDetailRow(label: "Device Category", value: device.deviceCategoryDisplayName)
            
            if isLoadingCompliance {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading compliance policies...").appFont(.caption).foregroundColor(.secondary)
                }
            } else if !compliancePolicies.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compliance Policies")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    ForEach(compliancePolicies, id: \.id) { policy in
                        HStack(spacing: 6) {
                            Image(systemName: policyStateIcon(policy.state))
                                .foregroundColor(policyStateColor(policy.state))
                                .appFont(.caption)
                            Text(policy.displayName ?? "Unknown Policy")
                                .appFont(.caption)
                            Spacer()
                            Text(policy.state ?? "Unknown")
                                .appFont(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Group Membership
    
    private var groupMembershipSection: some View {
        DetailSection(title: "Group Membership", icon: "person.3") {
            if isLoadingGroups {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading groups...").appFont(.caption).foregroundColor(.secondary)
                }
            } else if groupMemberships.isEmpty {
                Text("No group memberships found")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(groupMemberships, id: \.id) { group in
                    HStack(spacing: 6) {
                        Image(systemName: "person.3.fill")
                            .foregroundColor(.accentColor)
                            .appFont(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.displayName ?? "Unknown Group")
                                .appFont(.caption)
                                .fontWeight(.medium)
                            if let desc = group.description, !desc.isEmpty {
                                Text(desc)
                                    .appFont(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Managed Apps
    
    private var managedAppsSection: some View {
        DetailSection(title: "Detected Apps", icon: "app.badge.checkmark") {
            if isLoadingApps {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading apps...").appFont(.caption).foregroundColor(.secondary)
                }
            } else if detectedApps.isEmpty {
                Text("No detected apps found")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("\(detectedApps.count) apps detected")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                ForEach(detectedApps.prefix(50), id: \.id) { app in
                    HStack(spacing: 6) {
                        Image(systemName: "app.fill")
                            .foregroundColor(.accentColor)
                            .appFont(.caption2)
                        Text(app.displayName ?? "Unknown")
                            .appFont(.caption)
                        Spacer()
                        if let version = app.version, !version.isEmpty {
                            Text(version)
                                .appFont(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if detectedApps.count > 50 {
                    Text("... and \(detectedApps.count - 50) more")
                        .appFont(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadDeviceDetails() async {
        errorMessage = nil
        
        // Load groups, apps, and compliance in parallel
        async let groupsTask: () = loadGroups()
        async let appsTask: () = loadApps()
        async let complianceTask: () = loadCompliance()
        
        _ = await (groupsTask, appsTask, complianceTask)
    }
    
    private func loadGroups() async {
        guard let azureADDeviceId = device.azureADDeviceId, !azureADDeviceId.isEmpty else { return }
        isLoadingGroups = true
        defer { isLoadingGroups = false }
        
        do {
            groupMemberships = try await appState.graphService.getDeviceGroupMemberships(azureADDeviceId)
        } catch {
            dbg.warn("Failed to load device groups: \(error)", category: "devices")
        }
    }
    
    private func loadApps() async {
        isLoadingApps = true
        defer { isLoadingApps = false }
        
        do {
            detectedApps = try await appState.graphService.getDetectedApps(device.id)
        } catch {
            dbg.warn("Failed to load detected apps: \(error)", category: "devices")
        }
    }
    
    private func loadCompliance() async {
        isLoadingCompliance = true
        defer { isLoadingCompliance = false }
        
        do {
            compliancePolicies = try await appState.graphService.getDeviceCompliance(deviceId: device.id)
        } catch {
            dbg.warn("Failed to load compliance policies: \(error)", category: "devices")
        }
    }
    
    // MARK: - Helpers
    
    private var deviceIcon: String {
        let os = (device.operatingSystem ?? "").lowercased()
        if os.contains("mac") { return "laptopcomputer" }
        if os.contains("ios") || os.contains("ipad") { return "ipad" }
        if os.contains("windows") { return "desktopcomputer" }
        if os.contains("android") { return "phone" }
        return "desktopcomputer"
    }
    
    private var ownershipDisplay: String? {
        guard let ownership = device.managedDeviceOwnerType else { return nil }
        switch ownership.lowercased() {
        case "company": return "Corporate"
        case "personal": return "Personal"
        default: return ownership.capitalized
        }
    }
    
    private var osDisplay: String? {
        guard let os = device.operatingSystem else { return nil }
        if let ver = device.osVersion {
            return "\(os) \(ver)"
        }
        return os
    }
    
    private var enrollmentTypeDisplay: String? {
        guard let type = device.deviceEnrollmentType else { return nil }
        // Make camelCase readable
        let readable = type.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return readable.capitalized
    }
    
    private func formatDate(_ dateString: String?) -> String? {
        guard let dateString = dateString, !dateString.isEmpty else { return nil }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        var date = formatter.date(from: dateString)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: dateString)
        }
        
        guard let parsed = date else {
            return String(dateString.prefix(16)).replacingOccurrences(of: "T", with: " ")
        }
        
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: parsed)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
    
    private func policyStateIcon(_ state: String?) -> String {
        switch state?.lowercased() {
        case "compliant": return "checkmark.circle.fill"
        case "noncompliant", "error": return "xmark.circle.fill"
        case "conflict": return "exclamationmark.triangle.fill"
        default: return "questionmark.circle"
        }
    }
    
    private func policyStateColor(_ state: String?) -> Color {
        switch state?.lowercased() {
        case "compliant": return .green
        case "noncompliant", "error": return .red
        case "conflict": return .orange
        default: return .gray
        }
    }
}

// MARK: - Reusable Detail Components

struct DetailSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .appFont(.headline)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(.leading, 4)
        }
    }
}

struct DeviceDetailRow: View {
    let label: String
    let value: String?
    var monospaced: Bool = false
    
    var body: some View {
        if let value = value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 140, alignment: .leading)
                if monospaced {
                    Text(value)
                        .appFont(.caption, design: .monospaced)
                        .textSelection(.enabled)
                } else {
                    Text(value)
                        .appFont(.caption)
                        .textSelection(.enabled)
                }
                Spacer()
            }
        }
    }
}
