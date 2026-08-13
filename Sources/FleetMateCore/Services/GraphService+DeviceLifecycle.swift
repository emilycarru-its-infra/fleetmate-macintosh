import Foundation

// Device decommission surface: the Intune actions past wipe/retire, the Windows
// Autopilot registration, and the Entra device object — the three records that
// outlive a wipe and keep a machine looking enrolled long after it is gone.
public extension GraphService {

    // MARK: - Intune record

    /// Delete the Intune managedDevice record.
    ///
    /// Destructive to a *pending* wipe: the wipe command lives on the record, so
    /// deleting it before the device checks in and picks the command up cancels
    /// the wipe outright. Sequence this after the device has reported in, or
    /// accept that the wipe may never run.
    func deleteManagedDevices(_ deviceIds: [String]) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/managedDevices/\(deviceId)"
                    do {
                        try await self.deleteAction(url: url, headers: headers)
                        return BulkActionResult(deviceId: deviceId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: deviceId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Windows Fresh Start — reinstall Windows, optionally preserving user data,
    /// while keeping the device enrolled and Entra-joined. Windows only; Graph
    /// rejects it for any other platform.
    func freshStartDevices(_ deviceIds: [String], keepUserData: Bool = true) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for deviceId in deviceIds {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/managedDevices/\(deviceId)/cleanWindowsDevice"
                    do {
                        try await self.postAction(url: url, body: ["keepUserData": keepUserData], headers: headers)
                        return BulkActionResult(deviceId: deviceId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: deviceId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Fetch a single managedDevice by its id.
    func getManagedDevice(id deviceId: String) async throws -> IntuneDevice? {
        guard let headers = await headers() else { return nil }
        let url = "\(baseUrl)/deviceManagement/managedDevices/\(deviceId)"
        return try? await fetch(url: url, headers: headers) as IntuneDevice
    }

    // MARK: - Windows Autopilot

    /// List Autopilot device identities, optionally filtered with an OData
    /// expression.
    func getAutopilotDevices(filter: String? = nil, limit: Int = 100) async throws -> [WindowsAutopilotDevice] {
        guard let headers = await headers() else { return [] }

        var url = "\(baseUrl)/deviceManagement/windowsAutopilotDeviceIdentities?$top=\(pageSize(for: limit))"
        if let filter, !filter.isEmpty {
            let escaped = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
            url += "&$filter=\(escaped)"
        }

        var devices: [WindowsAutopilotDevice] = []
        while devices.count < limit, URL(string: url) != nil {
            let response: WindowsAutopilotDevicesResponse = try await fetch(url: url, headers: headers)
            devices.append(contentsOf: response.value)
            guard let nextLink = response.nextLink else { break }
            url = nextLink
        }
        return Array(devices.prefix(limit))
    }

    /// Find the Autopilot registration for a serial number.
    ///
    /// Autopilot's `$filter` supports `contains` on `serialNumber` but not
    /// `eq`, so the match is narrowed here rather than by Graph.
    func getAutopilotDeviceBySerial(_ serialNumber: String) async throws -> WindowsAutopilotDevice? {
        let trimmed = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "'", with: "''")
        let matches = try await getAutopilotDevices(filter: "contains(serialNumber,'\(escaped)')", limit: 25)
        return matches.first { $0.serialNumber?.caseInsensitiveCompare(trimmed) == .orderedSame } ?? matches.first
    }

    /// Delete Autopilot registrations, releasing the hardware hashes so the
    /// devices can be re-registered under another tenant or profile.
    func deleteAutopilotDevices(_ autopilotIds: [String]) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for autopilotId in autopilotIds {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/windowsAutopilotDeviceIdentities/\(autopilotId)"
                    do {
                        try await self.deleteAction(url: url, headers: headers)
                        return BulkActionResult(deviceId: autopilotId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: autopilotId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Assign a user to an Autopilot device, so the out-of-box experience
    /// pre-fills that account.
    func assignAutopilotUser(autopilotId: String, userPrincipalName: String, addressableUserName: String? = nil) async throws {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let url = "\(baseUrl)/deviceManagement/windowsAutopilotDeviceIdentities/\(autopilotId)/assignUserToDevice"
        var body: [String: Any] = ["userPrincipalName": userPrincipalName]
        if let addressableUserName, !addressableUserName.isEmpty {
            body["addressableUserName"] = addressableUserName
        }
        try await postAction(url: url, body: body, headers: headers)
    }

    /// Remove the assigned user from an Autopilot device.
    func unassignAutopilotUser(autopilotId: String) async throws {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let url = "\(baseUrl)/deviceManagement/windowsAutopilotDeviceIdentities/\(autopilotId)/unassignUserFromDevice"
        try await postAction(url: url, headers: headers)
    }

    // MARK: - Entra device objects

    /// Look up an Entra device object by its `deviceId` (the GUID Intune
    /// reports as `azureADDeviceId`), which is not the object id used in write
    /// paths.
    func getEntraDevice(deviceId: String) async throws -> EntraDevice? {
        guard let headers = await headers() else { return nil }
        let escaped = deviceId.replacingOccurrences(of: "'", with: "''")
        let filter = "deviceId eq '\(escaped)'".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = "\(baseUrl)/devices?$filter=\(filter)&$top=1"
        let response: EntraDeviceListResponse? = try? await fetch(url: url, headers: headers)
        return response?.value.first
    }

    /// Enable or disable an Entra device object by object id. A disabled device
    /// cannot obtain tokens, which blocks conditional-access resources
    /// immediately without destroying the record.
    func setEntraDeviceEnabled(objectId: String, enabled: Bool) async throws {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let url = "\(baseUrl)/devices/\(objectId)"
        try await patchAction(url: url, body: ["accountEnabled": enabled], headers: headers)
    }

    /// Delete Entra device objects by object id.
    func deleteEntraDevices(_ objectIds: [String]) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for objectId in objectIds {
                group.addTask {
                    let url = "\(self.baseUrl)/devices/\(objectId)"
                    do {
                        try await self.deleteAction(url: url, headers: headers)
                        return BulkActionResult(deviceId: objectId, success: true)
                    } catch {
                        return BulkActionResult(deviceId: objectId, success: false, error: error.localizedDescription)
                    }
                }
            }
            var results: [BulkActionResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    // MARK: - Offboard

    /// Resolve a serial number or managedDevice id to the full device record.
    func resolveManagedDevice(_ identifier: String) async throws -> IntuneDevice? {
        if UUID(uuidString: identifier) != nil, let device = try await getManagedDevice(id: identifier) {
            return device
        }
        if let device = try await getDeviceBySerial(identifier) { return device }
        return try await getDeviceByName(identifier)
    }

    /// Run a full decommission for one device.
    ///
    /// Steps run in the order they are safe in: the terminal Intune action
    /// first (it needs the record intact), then the Autopilot registration and
    /// the Entra object, and the Intune record last because deleting it cancels
    /// a wipe the device has not picked up yet.
    func offboardDevice(_ identifier: String, plan: OffboardPlan) async throws -> OffboardResult {
        guard let device = try await resolveManagedDevice(identifier) else {
            return OffboardResult(
                identifier: identifier,
                deviceName: nil,
                platform: .other,
                steps: [OffboardStepResult(step: "Resolve device", outcome: .failed, detail: "No Intune device matches \(identifier)")]
            )
        }
        return await offboardDevice(device, plan: plan)
    }

    /// Run a full decommission for an already-resolved device.
    func offboardDevice(_ device: IntuneDevice, plan: OffboardPlan) async -> OffboardResult {
        var steps: [OffboardStepResult] = []
        let platform = device.platform

        switch plan.terminalAction {
        case .wipe:
            let results = (try? await wipeDevices([device], options: plan.wipeOptions)) ?? []
            steps.append(Self.step("Wipe", from: results.first))
        case .retire:
            let results = (try? await retireDevices([device.id])) ?? []
            steps.append(Self.step("Retire", from: results.first))
        case .none:
            steps.append(OffboardStepResult(step: "Wipe or retire", outcome: .skipped, detail: "Not requested"))
        }

        if plan.deleteAutopilotRegistration {
            steps.append(await autopilotStep(for: device, platform: platform))
        }

        if plan.entraAction != .none {
            steps.append(await entraStep(for: device, action: plan.entraAction))
        }

        if plan.deleteIntuneRecord {
            let results = (try? await deleteManagedDevices([device.id])) ?? []
            steps.append(Self.step("Delete Intune record", from: results.first))
        }

        return OffboardResult(
            identifier: device.serialNumber ?? device.id,
            deviceName: device.deviceName,
            platform: platform,
            steps: steps
        )
    }

    /// Offboard several devices concurrently.
    func offboardDevices(_ devices: [IntuneDevice], plan: OffboardPlan) async -> [OffboardResult] {
        await withTaskGroup(of: OffboardResult.self) { group in
            for device in devices {
                group.addTask { await self.offboardDevice(device, plan: plan) }
            }
            var results: [OffboardResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    // MARK: - Dry run

    /// What an offboard would do, resolved against live data but writing
    /// nothing.
    ///
    /// Shares every lookup with `offboardDevice`, so a preview cannot drift
    /// from the run it describes: the ids printed here are the ids that would
    /// be deleted.
    func previewOffboard(_ device: IntuneDevice, plan: OffboardPlan) async -> [OffboardPlannedStep] {
        var steps: [OffboardPlannedStep] = []
        let platform = device.platform

        switch plan.terminalAction {
        case .wipe:
            let body = plan.wipeOptions.requestBody(for: platform)
            steps.append(OffboardPlannedStep(
                step: "Wipe",
                willRun: true,
                detail: "POST managedDevices/\(device.id)/wipe \(Self.describe(body))"
            ))
        case .retire:
            steps.append(OffboardPlannedStep(
                step: "Retire",
                willRun: true,
                detail: "POST managedDevices/\(device.id)/retire"
            ))
        case .none:
            steps.append(OffboardPlannedStep(step: "Wipe or retire", willRun: false, detail: "Not requested"))
        }

        if plan.deleteAutopilotRegistration {
            let target = await resolveAutopilotTarget(for: device, platform: platform)
            steps.append(OffboardPlannedStep(
                step: "Delete Autopilot registration",
                willRun: target.id != nil,
                detail: target.id.map { "DELETE windowsAutopilotDeviceIdentities/\($0)" } ?? (target.skipReason ?? "skipped")
            ))
        }

        if plan.entraAction != .none {
            let label = plan.entraAction == .delete ? "Delete Entra device" : "Disable Entra device"
            let target = await resolveEntraTarget(for: device)
            let verb = plan.entraAction == .delete
                ? "DELETE devices/"
                : "PATCH devices/"
            let suffix = plan.entraAction == .delete ? "" : " {\"accountEnabled\":false}"
            steps.append(OffboardPlannedStep(
                step: label,
                willRun: target.id != nil,
                detail: target.id.map { "\(verb)\($0)\(suffix)" } ?? (target.skipReason ?? "skipped")
            ))
        }

        if plan.deleteIntuneRecord {
            steps.append(OffboardPlannedStep(
                step: "Delete Intune record",
                willRun: true,
                detail: "DELETE managedDevices/\(device.id)"
            ))
        }

        return steps
    }

    /// Render a request body the way the dry run shows it — sorted so two runs
    /// of the same plan print identically.
    static func describe(_ body: [String: Any]) -> String {
        let pairs = body.keys.sorted().map { key -> String in
            let value = body[key]
            if let bool = value as? Bool { return "\"\(key)\":\(bool)" }
            if let string = value as? String { return "\"\(key)\":\"\(string)\"" }
            return "\"\(key)\":\(String(describing: value ?? "null"))"
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    // MARK: - Offboard step helpers

    /// Resolved downstream record, or why there is nothing to act on.
    struct LifecycleTarget {
        let id: String?
        let skipReason: String?
    }

    private func resolveAutopilotTarget(for device: IntuneDevice, platform: DevicePlatform) async -> LifecycleTarget {
        guard platform == .windows else {
            return LifecycleTarget(id: nil, skipReason: "\(platform.displayName) devices have no Autopilot registration")
        }
        guard let serial = device.serialNumber, !serial.isEmpty else {
            return LifecycleTarget(id: nil, skipReason: "Device has no serial number to match on")
        }
        guard let autopilot = try? await getAutopilotDeviceBySerial(serial), let autopilotId = autopilot.id else {
            return LifecycleTarget(id: nil, skipReason: "No Autopilot registration for \(serial)")
        }
        return LifecycleTarget(id: autopilotId, skipReason: nil)
    }

    private func resolveEntraTarget(for device: IntuneDevice) async -> LifecycleTarget {
        guard let azureADDeviceId = device.azureADDeviceId, !azureADDeviceId.isEmpty else {
            return LifecycleTarget(id: nil, skipReason: "Device is not Entra-joined or registered")
        }
        guard let entraDevice = try? await getEntraDevice(deviceId: azureADDeviceId), let objectId = entraDevice.id else {
            return LifecycleTarget(id: nil, skipReason: "No Entra device object for \(azureADDeviceId)")
        }
        return LifecycleTarget(id: objectId, skipReason: nil)
    }

    private func autopilotStep(for device: IntuneDevice, platform: DevicePlatform) async -> OffboardStepResult {
        let label = "Delete Autopilot registration"
        let target = await resolveAutopilotTarget(for: device, platform: platform)
        guard let autopilotId = target.id else {
            return OffboardStepResult(step: label, outcome: .skipped, detail: target.skipReason)
        }
        let results = (try? await deleteAutopilotDevices([autopilotId])) ?? []
        return Self.step(label, from: results.first)
    }

    private func entraStep(for device: IntuneDevice, action: OffboardPlan.EntraAction) async -> OffboardStepResult {
        let label = action == .delete ? "Delete Entra device" : "Disable Entra device"
        let target = await resolveEntraTarget(for: device)
        guard let objectId = target.id else {
            return OffboardStepResult(step: label, outcome: .skipped, detail: target.skipReason)
        }

        if action == .delete {
            let results = (try? await deleteEntraDevices([objectId])) ?? []
            return Self.step(label, from: results.first)
        }

        do {
            try await setEntraDeviceEnabled(objectId: objectId, enabled: false)
            return OffboardStepResult(step: label, outcome: .succeeded)
        } catch {
            return OffboardStepResult(step: label, outcome: .failed, detail: error.localizedDescription)
        }
    }

    private static func step(_ label: String, from result: BulkActionResult?) -> OffboardStepResult {
        guard let result else {
            return OffboardStepResult(step: label, outcome: .failed, detail: "No response — not authenticated?")
        }
        return result.success
            ? OffboardStepResult(step: label, outcome: .succeeded)
            : OffboardStepResult(step: label, outcome: .failed, detail: result.error)
    }
}
