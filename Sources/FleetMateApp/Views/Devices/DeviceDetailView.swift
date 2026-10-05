import SwiftUI
import FleetMateCore

/// The device inspector. The device's platform and the systems that know it
/// decide which sections appear; nothing that cannot apply is shown.
struct DeviceDetailView: View {
    @EnvironmentObject var appState: AppState
    let row: DeviceListRow

    private var intune: IntuneDevice? { row.intune }
    private var apple: AppleOrgDevice? { row.apple }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    summarySection
                    Divider()
                    // The device's own sources decide what shows: the Apple
                    // organization's section for a device it holds,
                    // Autopilot's for a registered Windows device, Intune's
                    // for an enrolled one.
                    if AppleOrgDetailSection.applies(to: row, store: appState.appleOrg) {
                        AppleOrgDetailSection(store: appState.appleOrg, row: row)
                        if intune != nil || row.autopilot != nil { Divider() }
                    }
                    if let identity = row.autopilot {
                        AutopilotDetailSection(identity: identity, registration: row.registration)
                        if intune != nil { Divider() }
                    }
                    if let intune {
                        IntuneDeviceSections(device: intune)
                    }
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Image(systemName: deviceIcon)
                .appFont(.title)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(intune?.deviceName ?? apple?.model ?? "Unknown Device")
                    .appFont(.title2)
                    .fontWeight(.bold)
                    .textSelection(.enabled)
                Text(intune?.managedDeviceName ?? row.serialNumber ?? "")
                    .appFont(.subheadline)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            ComplianceBadge(state: intune == nil ? "Not Enrolled" : intune?.complianceState)
        }
        .padding()
    }

    /// The device as a whole, from whichever record has each value.
    private var summarySection: some View {
        DetailSection(title: "Summary", icon: "info.circle") {
            DeviceDetailRow(label: "Device Name", value: intune?.deviceName)
            DeviceDetailRow(label: "Serial Number", value: row.serialNumber, monospaced: true)
            DeviceDetailRow(label: "Platform", value: row.platformLabel)
            DeviceDetailRow(label: "Model", value: intune?.model ?? apple?.model)
            DeviceDetailRow(label: "OS", value: [intune?.operatingSystem, intune?.osVersion].compactMap { $0 }.joined(separator: " "))
            DeviceDetailRow(label: "Primary User", value: intune?.userDisplayName ?? intune?.userPrincipalName)
            DeviceDetailRow(label: "Last Check-in", value: intune?.lastSyncDateTime.map { AppleOrgFormat.isoDate($0) })
            DeviceDetailRow(label: "Enrollment", value: row.isEnrolled ? nil : "Not enrolled in Intune")
        }
    }

    private var deviceIcon: String {
        let os = (row.platformLabel ?? "").lowercased()
        if os.contains("mac") { return "laptopcomputer" }
        if os.contains("ios") || os.contains("ipad") { return "ipad" }
        if os.contains("windows") { return "desktopcomputer" }
        if os.contains("android") { return "phone" }
        return "desktopcomputer"
    }
}

/// The Intune record's sections, which load groups, apps and compliance.
private struct IntuneDeviceSections: View {
    @EnvironmentObject var appState: AppState
    let device: IntuneDevice

    @State private var groupMemberships: [DeviceGroupMembership] = []
    @State private var detectedApps: [DetectedApp] = []
    @State private var compliancePolicies: [DeviceCompliancePolicyState] = []
    @State private var isLoadingGroups = false
    @State private var isLoadingApps = false
    @State private var isLoadingCompliance = false
    @State private var errorMessage: String?
    @State private var selectedPolicy: SelectedCompliancePolicy?
    @State private var pendingSecret: RecoverySecretKind?
    @State private var revealingSecret: RecoverySecretKind?

    /// Wraps a policy state so the sheet has a stable, non-optional id.
    private struct SelectedCompliancePolicy: Identifiable {
        let id: String
        let policy: DeviceCompliancePolicyState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = errorMessage {
                Text(error)
                    .appFont(.caption)
                    .foregroundColor(.orange)
            }
            deviceSummarySection
            Divider()
            groupMembershipSection
            Divider()
            enrollmentSection
            Divider()
            if !availableSecrets.isEmpty {
                recoverySecretsSection
                Divider()
            }
            hardwareSection
            Divider()
            complianceSection
            Divider()
            managedAppsSection
        }
        .task(id: device.id) {
            await loadDeviceDetails()
        }
        .sheet(item: $selectedPolicy) { selected in
            CompliancePolicyLightboxView(device: device, policy: selected.policy)
                .environmentObject(appState)
        }
        .sheet(item: $revealingSecret) { kind in
            RecoverySecretSheet(kind: kind, device: device)
                .environmentObject(appState)
        }
        .confirmationDialog(
            pendingSecret.map { "Show the \($0.displayName.lowercased())?" } ?? "",
            isPresented: Binding(
                get: { pendingSecret != nil },
                set: { if !$0 { pendingSecret = nil } }
            ),
            presenting: pendingSecret
        ) { kind in
            Button("Show") { revealingSecret = kind }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The value is fetched for \(device.deviceName ?? "this device") only, shown once and not saved. The read is recorded in the directory audit log.")
        }
        .onChange(of: device.id) { _, _ in
            pendingSecret = nil
            revealingSecret = nil
        }
    }

    // MARK: - Device Summary
    
    private var deviceSummarySection: some View {
        DetailSection(title: "Device Management Service", icon: "shield.lefthalf.filled") {
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
    
    // MARK: - Recovery Secrets

    private var availableSecrets: [RecoverySecretKind] {
        RecoverySecretKind.available(for: device.platform)
    }

    private var recoverySecretsSection: some View {
        DetailSection(title: "Recovery Secrets", icon: "lock.shield") {
            HStack(spacing: 8) {
                ForEach(availableSecrets) { kind in
                    Button {
                        pendingSecret = kind
                    } label: {
                        Label(kind.displayName, systemImage: kind.systemImage)
                    }
                    .controlSize(.small)
                    .help("Fetch and show this device's \(kind.displayName.lowercased())")
                }
            }
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
            DeviceDetailRow(label: "Jailbroken", value: device.jailBroken)
            
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
                        Button {
                            selectedPolicy = SelectedCompliancePolicy(id: policy.id ?? policy.displayName ?? UUID().uuidString, policy: policy)
                        } label: {
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
                                Image(systemName: "chevron.right")
                                    .appFont(.caption2)
                                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open the full policy evaluation for this device")
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
        case "noncompliant", "error": return .orange
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
