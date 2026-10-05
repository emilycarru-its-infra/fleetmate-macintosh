import Foundation

// The Autopilot lifecycle surface behind the Devices tab: the whole tenant's
// identities in one read, and the bulk actions on them. Single-identity reads
// and deletes live with the decommission code in GraphService+DeviceLifecycle.
public extension GraphService {

    /// Every Autopilot identity in the tenant. Graph cannot filter them by
    /// serial with `eq`, so the device list reads them all and matches locally.
    func getAllAutopilotDevices() async throws -> [WindowsAutopilotDevice] {
        try await getAutopilotDevices(limit: 100_000)
    }

    /// Run an Autopilot action on identities, concurrently. Results carry the
    /// Autopilot identity id.
    func performAutopilotAction(_ action: AutopilotAction, autopilotIds: [String]) async throws -> [BulkActionResult] {
        if action == .delete { return try await deleteAutopilotDevices(autopilotIds) }
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }

        return await withTaskGroup(of: BulkActionResult.self) { group in
            for autopilotId in autopilotIds {
                group.addTask {
                    let base = "\(self.baseUrl)/deviceManagement/windowsAutopilotDeviceIdentities/\(autopilotId)"
                    do {
                        switch action {
                        case .setGroupTag(let tag):
                            try await self.postAction(url: "\(base)/updateDeviceProperties", body: ["groupTag": tag], headers: headers)
                        case .assignUser(let upn):
                            try await self.assignAutopilotUser(autopilotId: autopilotId, userPrincipalName: upn)
                        case .unassignUser:
                            try await self.unassignAutopilotUser(autopilotId: autopilotId)
                        case .delete:
                            break
                        }
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

    /// Submit hardware hashes for registration. Intune processes them in the
    /// background; poll `getImportedAutopilotIdentities` for the outcome.
    func importAutopilotHashes(_ entries: [AutopilotHashEntry]) async throws -> [ImportedAutopilotIdentity] {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let identities: [[String: Any]] = entries.map { entry in
            var item: [String: Any] = [
                "@odata.type": "#microsoft.graph.importedWindowsAutopilotDeviceIdentity",
                "serialNumber": entry.serialNumber,
                "hardwareIdentifier": entry.hardwareHash,
            ]
            if let key = entry.productKey { item["productKey"] = key }
            if let tag = entry.groupTag { item["groupTag"] = tag }
            if let user = entry.assignedUser { item["assignedUserPrincipalName"] = user }
            return item
        }
        let url = "\(baseUrl)/deviceManagement/importedWindowsAutopilotDeviceIdentities/import"
        let response: ImportedAutopilotIdentitiesResponse = try await post(
            url: url, body: ["importedWindowsAutopilotDeviceIdentities": identities], headers: headers)
        return response.value
    }

    /// Re-read imported hashes by id. One that can no longer be read keeps its
    /// last known state in the caller.
    func getImportedAutopilotIdentities(ids: [String]) async throws -> [ImportedAutopilotIdentity] {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        return await withTaskGroup(of: ImportedAutopilotIdentity?.self) { group in
            for id in ids {
                group.addTask {
                    let url = "\(self.baseUrl)/deviceManagement/importedWindowsAutopilotDeviceIdentities/\(id)"
                    return try? await self.fetch(url: url, headers: headers) as ImportedAutopilotIdentity
                }
            }
            var out: [ImportedAutopilotIdentity] = []
            for await item in group { if let item { out.append(item) } }
            return out
        }
    }

    /// Ask Autopilot to sync with Intune, which is what makes a fresh import
    /// or a group tag change reach deployment profile assignment sooner.
    /// Intune rate-limits this to one sync every ten minutes.
    func syncAutopilot() async throws {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        try await postAction(url: "\(baseUrl)/deviceManagement/windowsAutopilotSettings/sync", headers: headers)
    }
}
