import Foundation

/// Outcome of removing a machine's stale Entra device twins.
public struct StaleTwinCleanup: Sendable {
    public var deleted: [String] = []
    public var failed: [String] = []
    /// Deleted twins that were synced from on-prem Active Directory. Entra Connect
    /// re-creates each one on its next cycle while the computer object still exists
    /// in a synced OU, so the operator has to retire that object as well.
    public var resyncRisk: [String] = []
    /// Why nothing was attempted, when nothing was.
    public var skippedReason: String?
}

extension GraphService {

    /// Entra device objects by display name. Duplicates are the point — every
    /// match is returned, because a re-joined machine leaves one per join.
    func getEntraDevices(displayName: String) async throws -> [EntraDevice] {
        guard let headers = await headers() else { return [] }
        let escaped = displayName.replacingOccurrences(of: "'", with: "''")
        let filter = "displayName eq '\(escaped)'".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = "\(baseUrl)/devices?$filter=\(filter)&$top=50"
        let response: EntraDeviceListResponse? = try? await fetch(url: url, headers: headers)
        return response?.value ?? []
    }

    /// Delete the Entra objects that are bound to neither the machine's Autopilot
    /// identity nor its live Intune record: hybrid (ServerAd) and registered
    /// (Workplace) leftovers from before it left the domain, and duplicate AzureAd
    /// objects from earlier joins. Left in place they fail the next OOBE and wedge
    /// the Enrollment Status Page.
    ///
    /// The Autopilot identity, the Intune record and the Entra object bound to them
    /// are always kept — that is the enrollment the device comes back to. With no
    /// Autopilot identity there is no way to tell the live object from a stale one,
    /// so nothing is deleted.
    ///
    /// Call this with names captured *before* the wipe: the reset renames the bound
    /// object to the profile template, and the old name is what finds the twins.
    public func cleanStaleEntraTwins(serial: String, knownNames: [String], liveAzureADDeviceId: String?) async -> StaleTwinCleanup {
        var outcome = StaleTwinCleanup()

        let autopilot = try? await getAutopilotDeviceBySerial(serial)
        var bound = Set<String>()
        if let id = autopilot?.azureActiveDirectoryDeviceId, !id.isEmpty { bound.insert(id.lowercased()) }
        if let id = liveAzureADDeviceId, !id.isEmpty { bound.insert(id.lowercased()) }

        guard !bound.isEmpty else {
            outcome.skippedReason = "no Autopilot identity or live Entra binding to tell the live object from a stale one"
            return outcome
        }

        var names = Set(knownNames.filter { !$0.isEmpty })
        for id in bound {
            if let bindingObject = try? await getEntraDevice(deviceId: id), let name = bindingObject.displayName, !name.isEmpty {
                names.insert(name)
            }
        }

        var seen = Set<String>()
        var twins: [EntraDevice] = []
        for name in names {
            let matches = (try? await getEntraDevices(displayName: name)) ?? []
            for device in matches {
                guard let objectId = device.id, seen.insert(objectId).inserted else { continue }
                let deviceId = (device.deviceId ?? "").lowercased()
                if deviceId.isEmpty || !bound.contains(deviceId) { twins.append(device) }
            }
        }

        guard !twins.isEmpty else { return outcome }

        let results = (try? await deleteEntraDevices(twins.compactMap(\.id))) ?? []
        for twin in twins {
            let label = "stale Entra twin \(twin.id ?? "?") (\(twin.displayName ?? "?"), \(twin.trustType ?? "unknown trust"))"
            let result = results.first { $0.deviceId == twin.id }
            if result?.success == true {
                outcome.deleted.append(label)
                if twin.trustType?.caseInsensitiveCompare("ServerAd") == .orderedSame {
                    outcome.resyncRisk.append(twin.displayName ?? twin.id ?? "?")
                }
            } else {
                outcome.failed.append("\(label): \(result?.error ?? "no result")")
            }
        }
        return outcome
    }
}
