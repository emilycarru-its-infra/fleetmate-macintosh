import Foundation

/// Recovery secrets for one device at a time. Nothing here caches or logs a
/// value: the caller gets it back once and decides how long to hold it.
extension GraphService {

    /// Graph asks callers reading BitLocker keys and LAPS passwords to name
    /// themselves, for the directory audit log.
    static let auditClientHeaders = [
        "ocp-client-name": "FleetMate",
        "ocp-client-version": "1.0",
    ]

    public func revealRecoverySecret(
        _ kind: RecoverySecretKind,
        for device: IntuneDevice
    ) async throws -> [RevealedSecret] {
        switch kind {
        case .fileVault: return [try await fileVaultKey(for: device)]
        case .macOSLAPS: return [try await macOSLocalAdmin(for: device)]
        case .bitLocker: return try await bitLockerKeys(for: device)
        case .windowsLAPS: return [try await windowsLocalAdmin(for: device)]
        }
    }

    private func fileVaultKey(for device: IntuneDevice) async throws -> RevealedSecret {
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let url = "\(betaBaseURL)/deviceManagement/managedDevices/\(device.id)/getFileVaultKey"
        let response: FileVaultKeyResponse = try await fetch(url: url, headers: headers)
        guard let key = response.value, !key.isEmpty else {
            throw RecoverySecretError.notEscrowed("FileVault recovery key")
        }
        return RevealedSecret(id: "filevault", label: "Personal Recovery Key", value: key)
    }

    private func macOSLocalAdmin(for device: IntuneDevice) async throws -> RevealedSecret {
        guard let serial = device.serialNumber, !serial.isEmpty else {
            throw MacOSLAPSLookupError.deviceNotFound("(none)")
        }
        let credential = try await getMacOSLocalAdminCredential(serialNumber: serial)
        return RevealedSecret(
            id: "macos-laps",
            label: "Password",
            value: credential.adminAccountPassword,
            detail: credential.passwordLastRotatedDateTime.map { "Last rotated \($0)" }
        )
    }

    private func bitLockerKeys(for device: IntuneDevice) async throws -> [RevealedSecret] {
        let entraId = try entraDeviceId(of: device)
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let filter = "deviceId eq '\(entraId)'"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let list: BitLockerRecoveryKeyListResponse = try await fetch(
            url: "\(baseUrl)/informationProtection/bitlocker/recoveryKeys?$filter=\(filter)",
            headers: headers,
            extraHeaders: Self.auditClientHeaders
        )
        guard !list.value.isEmpty else {
            throw RecoverySecretError.notEscrowed("BitLocker recovery key")
        }

        // The key itself is only served one record at a time.
        var secrets: [RevealedSecret] = []
        for record in list.value.sorted(by: { ($0.createdDateTime ?? "") > ($1.createdDateTime ?? "") }) {
            let full: BitLockerRecoveryKey = try await fetch(
                url: "\(baseUrl)/informationProtection/bitlocker/recoveryKeys/\(record.id)?$select=key",
                headers: headers,
                extraHeaders: Self.auditClientHeaders
            )
            guard let key = full.key, !key.isEmpty else { continue }
            secrets.append(RevealedSecret(
                id: record.id,
                label: record.volumeDisplayName,
                value: key,
                detail: "Key ID \(record.id)" + (record.createdDateTime.map { " · backed up \($0)" } ?? "")
            ))
        }
        guard !secrets.isEmpty else { throw RecoverySecretError.notEscrowed("BitLocker recovery key") }
        return secrets
    }

    private func windowsLocalAdmin(for device: IntuneDevice) async throws -> RevealedSecret {
        let entraId = try entraDeviceId(of: device)
        guard let headers = await headers() else { throw GraphServiceError.notAuthenticated }
        let info: DeviceLocalCredentialInfo = try await fetch(
            url: "\(baseUrl)/directory/deviceLocalCredentials/\(entraId)?$select=credentials",
            headers: headers,
            extraHeaders: Self.auditClientHeaders
        )
        guard let credential = info.latestCredential, let password = credential.password else {
            throw RecoverySecretError.notEscrowed("local administrator password")
        }
        var detail = credential.accountName.map { "Account \($0)" } ?? ""
        if let backedUp = credential.backupDateTime {
            detail += (detail.isEmpty ? "" : " · ") + "backed up \(backedUp)"
        }
        return RevealedSecret(
            id: "windows-laps",
            label: "Password",
            value: password,
            detail: detail.isEmpty ? nil : detail
        )
    }

    private func entraDeviceId(of device: IntuneDevice) throws -> String {
        guard let id = device.azureADDeviceId, !id.isEmpty,
              id != "00000000-0000-0000-0000-000000000000" else {
            throw RecoverySecretError.missingEntraDeviceId
        }
        return id
    }
}
