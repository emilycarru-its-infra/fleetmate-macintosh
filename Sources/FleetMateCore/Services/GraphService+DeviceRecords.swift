import Alamofire
import Foundation

/// What the three directory records say about one machine, gathered in one
/// place so a re-provisioning failure can be read at a glance.
public struct DeviceRecordState: Codable, Sendable {
    public var serial: String
    public var autopilot: WindowsAutopilotDevice?
    public var intune: IntuneDevice?
    public var entraDevices: [EntraDevice] = []

    /// True when at least one lookup never reached Graph, so the absences are
    /// unknowns rather than facts. Nothing may report "no records", and nothing
    /// may be deleted, while this is set.
    public var lookupFailed = false
    public var lookupError: String?

    /// Why a destructive action must not proceed even though the lookup worked:
    /// the input was not a valid serial, or it matched more than one record.
    /// Set together with the candidates so the caller can list them.
    public var refusal: String?
    public var intuneCandidates: [IntuneDevice] = []
    public var autopilotCandidates: [WindowsAutopilotDevice] = []

    /// True only when the records were read and identify one machine.
    public var canAct: Bool { !lookupFailed && refusal == nil }

    /// Entra still holds a device object but Intune has no record — the state
    /// that fails the next OOBE at "Registering your device for mobile management".
    public var isOrphaned: Bool { intune == nil && !entraDevices.isEmpty }

    /// The Autopilot identity points at a managedDevice that no longer exists.
    public var hasDanglingManagedDeviceId: Bool {
        guard let id = autopilot?.managedDeviceId, !id.isEmpty, !id.allSatisfy({ $0 == "0" || $0 == "-" }) else { return false }
        return intune == nil
    }

    public init(serial: String) { self.serial = serial }
}

/// Outcome of a directory-record cleanup for one machine.
public struct RecordCleanupResult: Codable, Sendable {
    public var serial: String
    public var success = false
    public var deleted: [String] = []
    public var skipped: [String] = []
    public var errors: [String] = []
    /// The Autopilot identity, always retained — reported so the caller can prove it survived.
    public var retainedAutopilotId: String?
    /// The records could not be read, so nothing was attempted.
    public var lookupFailed = false
    /// Deleted objects synced from on-prem Active Directory, which Entra Connect
    /// re-creates while the computer object still exists in a synced OU.
    public var resyncRisk: [String] = []

    public init(serial: String) { self.serial = serial }
}

extension DeviceRecordState {
    /// Entra objects bound to neither the Autopilot identity nor the live Intune
    /// record: hybrid and registered leftovers and duplicate joins. With nothing
    /// bound there is no way to tell the live object from a stale one, so nothing
    /// counts as a twin.
    public var staleEntraTwins: [EntraDevice] {
        var bound = Set<String>()
        if let id = autopilot?.azureActiveDirectoryDeviceId, !id.isEmpty { bound.insert(id.lowercased()) }
        if let id = intune?.azureADDeviceId, !id.isEmpty { bound.insert(id.lowercased()) }
        guard !bound.isEmpty else { return [] }
        return entraDevices.filter { device in
            guard let deviceId = device.deviceId, !deviceId.isEmpty else { return true }
            return !bound.contains(deviceId.lowercased())
        }
    }
}

extension GraphService {

    /// Gather the Autopilot identity, the Intune record and every Entra device
    /// object for one serial. Entra objects are found both through the deviceId
    /// the Autopilot identity and Intune record point at, and by display name,
    /// because an orphan is exactly the case where one of those links is broken.
    public func getDeviceRecordState(serial rawSerial: String) async -> DeviceRecordState {
        var state = DeviceRecordState(serial: rawSerial)
        let serial: String
        do {
            serial = try DeviceIdentifier.validateSerial(rawSerial)
        } catch {
            state.refusal = error.localizedDescription
            return state
        }
        state.serial = serial
        guard let headers = await headers() else {
            state.lookupFailed = true
            state.lookupError = "Not authenticated to Microsoft Graph"
            return state
        }

        do {
            // Exact serial matches only, and all of them: a second record with
            // the same serial is a refusal, never "take the first".
            let autopilot = try await autopilotDevices(exactSerial: serial)
            let intune = ExactMatch.resolve(
                try await getManagedDevices(filter: ODataFilter.equals("serialNumber", serial), limit: 10),
                matching: serial) { $0.serialNumber }
            switch intune {
            case .one(let device): state.intune = device
            case .many(let devices):
                state.intuneCandidates = devices
                state.refusal = "\(devices.count) Intune records have serial \(serial); refusing to choose one."
            case .none: break
            }
            if autopilot.count == 1 {
                state.autopilot = autopilot[0]
            } else if autopilot.count > 1 {
                state.autopilotCandidates = autopilot
                state.refusal = state.refusal ?? "\(autopilot.count) Autopilot identities have serial \(serial); refusing to choose one."
            }
            guard state.refusal == nil else { return state }

            var seen = Set<String>()
            func add(_ devices: [EntraDevice]) {
                for device in devices {
                    guard let id = device.id, seen.insert(id.lowercased()).inserted else { continue }
                    state.entraDevices.append(device)
                }
            }

            for deviceId in [state.autopilot?.azureActiveDirectoryDeviceId, state.intune?.azureADDeviceId] {
                guard let deviceId, !deviceId.isEmpty else { continue }
                add(try await entraDevices(filter: ODataFilter.equals("deviceId", deviceId), headers: headers))
            }

            let intuneName = state.intune?.deviceName
            if let name = intuneName, !name.isEmpty {
                add(try await entraDevices(filter: ODataFilter.equals("displayName", name), headers: headers))
            }
            // A machine that already lost its Intune record has no name to search
            // by, but the objects found through Autopilot carry the names it has
            // gone by.
            let knownNames = Set(state.entraDevices.compactMap(\.displayName).filter {
                !$0.isEmpty && $0.caseInsensitiveCompare(intuneName ?? "") != .orderedSame
            })
            for name in knownNames {
                add(try await entraDevices(filter: ODataFilter.equals("displayName", name), headers: headers))
            }
        } catch {
            state.lookupFailed = true
            state.lookupError = error.localizedDescription
        }
        return state
    }

    /// Remove the stale directory records that block a machine from re-enrolling:
    /// the Intune managedDevice and every Entra device object for it. The Autopilot
    /// identity is kept — it holds the hardware hash, and the next enrollment
    /// re-creates both deleted records. Refuses to act when the lookup failed.
    public func cleanDeviceRecords(serial: String) async -> RecordCleanupResult {
        var result = RecordCleanupResult(serial: serial)
        let state = await getDeviceRecordState(serial: serial)

        guard !state.lookupFailed else {
            result.lookupFailed = true
            result.errors.append("Could not read the current records for \(serial), so nothing was changed. \(state.lookupError ?? "")")
            return result
        }
        if let refusal = state.refusal {
            result.errors.append("\(refusal) Nothing was changed.")
            return result
        }
        result.retainedAutopilotId = state.autopilot?.id

        if let intune = state.intune {
            let deleted = (try? await deleteManagedDevices([intune.id])) ?? []
            if deleted.first?.success == true {
                result.deleted.append("Intune managedDevice \(intune.id) (\(intune.deviceName ?? "unnamed"))")
            } else {
                result.errors.append("Intune managedDevice \(intune.id): \(deleted.first?.error ?? "not deleted")")
            }
        } else {
            result.skipped.append("Intune managedDevice: no record")
        }

        for entra in state.entraDevices {
            guard let objectId = entra.id else { continue }
            let label = "Entra device \(objectId) (\(entra.displayName ?? "unnamed"), \(entra.trustType ?? "unknown trust"))"
            let deleted = (try? await deleteEntraDevices([objectId])) ?? []
            if deleted.first?.success == true {
                result.deleted.append(label)
                if entra.trustType?.caseInsensitiveCompare("ServerAd") == .orderedSame {
                    result.resyncRisk.append(entra.displayName ?? objectId)
                }
            } else {
                result.errors.append("\(label): \(deleted.first?.error ?? "not deleted")")
            }
        }
        if state.entraDevices.isEmpty { result.skipped.append("Entra device object: no record") }

        result.success = result.errors.isEmpty
        return result
    }

    /// Autopilot Reset: return a Windows device to OOBE, keeping the OS and its
    /// enrollment (`cleanWindowsDevice`).
    public func autopilotResetDevices(_ deviceIds: [String], keepUserData: Bool = false) async throws -> [BulkActionResult] {
        guard let headers = await headers() else { return [] }
        var results: [BulkActionResult] = []
        for id in deviceIds {
            guard (try? DeviceIdentifier.validateGuid(id)) != nil else {
                results.append(BulkActionResult(deviceId: id, success: false, error: "Not a managedDevice id"))
                continue
            }
            let url = "\(baseUrl)/deviceManagement/managedDevices/\(id)/cleanWindowsDevice"
            do {
                try await postAction(url: url, body: ["keepUserData": keepUserData], headers: headers)
                results.append(BulkActionResult(deviceId: id, success: true))
            } catch {
                results.append(BulkActionResult(deviceId: id, success: false, error: error.localizedDescription))
            }
        }
        return results
    }

    /// Delete Intune managedDevice records by id (server-side only).
    public func deleteIntuneRecords(_ deviceIds: [String]) async throws -> [BulkActionResult] {
        try await deleteManagedDevices(deviceIds)
    }

    /// Entra device objects by exact display name or, for a GUID, by deviceId
    /// or object id. Read-only lookups may use a name; destructive callers use
    /// `findEntraDevices(id:)`.
    public func findEntraDevices(_ query: String) async throws -> [EntraDevice] {
        if let id = try? DeviceIdentifier.validateGuid(query) { return try await findEntraDevices(id: id) }
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw DeviceIdentifierError("An empty name matches nothing.") }
        return try await entraDevices(filter: ODataFilter.equals("displayName", name), headers: headers)
    }

    /// Entra device objects by GUID only: the deviceId, else the object id.
    public func findEntraDevices(id rawId: String) async throws -> [EntraDevice] {
        let id = try DeviceIdentifier.validateGuid(rawId)
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let byDeviceId = try await entraDevices(filter: ODataFilter.equals("deviceId", id), headers: headers)
        if !byDeviceId.isEmpty { return byDeviceId }
        let byObjectId: EntraDevice? = try? await fetch(url: "\(baseUrl)/devices/\(id)", headers: headers)
        return byObjectId.map { [$0] } ?? []
    }

    /// Delete Entra device objects by object id.
    public func deleteEntraDeviceObjects(_ objectIds: [String]) async throws -> [BulkActionResult] {
        try await deleteEntraDevices(objectIds)
    }

    /// Append one line to a managed device's Intune notes (a beta-only property).
    /// Returns false rather than throwing: a failed note never undoes the action
    /// it records, it only tells the caller to note the reason by hand.
    public func appendManagedDeviceNote(_ managedDeviceId: String, line: String) async -> Bool {
        guard let headers = await headers() else { return false }
        let url = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/\(managedDeviceId)"
        struct Notes: Decodable { let notes: String? }
        do {
            let current: Notes = try await fetch(url: "\(url)?$select=id,notes", headers: headers)
            let existing = current.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let notes = existing.isEmpty ? line : "\(existing)\n\(line)"
            try await patchAction(url: url, body: ["notes": notes], headers: headers)
            return true
        } catch {
            return false
        }
    }

    private func entraDevices(filter: String, headers: HTTPHeaders) async throws -> [EntraDevice] {
        let encoded = ODataFilter.encode(filter)
        let response: EntraDeviceListResponse = try await fetch(url: "\(baseUrl)/devices?$filter=\(encoded)&$top=50", headers: headers)
        return response.value
    }
}
