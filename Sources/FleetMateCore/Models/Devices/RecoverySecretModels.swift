import Foundation

// MARK: - Recovery secrets

/// A secret FleetMate can reveal for a single device. Each one is fetched only
/// when asked for, shown once, and never cached, exported or logged.
public enum RecoverySecretKind: String, CaseIterable, Identifiable, Sendable {
    case fileVault
    case macOSLAPS
    case bitLocker
    case windowsLAPS

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fileVault: "FileVault Recovery Key"
        case .macOSLAPS: "Local Admin Password"
        case .bitLocker: "BitLocker Recovery Keys"
        case .windowsLAPS: "Local Admin Password"
        }
    }

    public var systemImage: String {
        switch self {
        case .fileVault, .bitLocker: "key"
        case .macOSLAPS, .windowsLAPS: "person.badge.key"
        }
    }

    /// The secrets that exist for a platform, in menu order.
    public static func available(for platform: DevicePlatform) -> [RecoverySecretKind] {
        switch platform {
        case .macOS: [.fileVault, .macOSLAPS]
        case .windows: [.bitLocker, .windowsLAPS]
        case .ios, .android, .other: []
        }
    }
}

/// One revealed value, labelled for the sheet. `detail` carries context such
/// as the account name or the volume, never another secret.
public struct RevealedSecret: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let value: String
    public let detail: String?

    public init(id: String, label: String, value: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.detail = detail
    }
}

public enum RecoverySecretError: Error, CustomStringConvertible, Equatable {
    case missingEntraDeviceId
    case unsupportedPlatform(String)
    case notEscrowed(String)

    public var description: String {
        switch self {
        case .missingEntraDeviceId:
            return "This device has no Entra device ID, so its keys cannot be looked up"
        case .unsupportedPlatform(let platform):
            return "No recovery secrets are available for \(platform)"
        case .notEscrowed(let what):
            return "No \(what) has been escrowed for this device"
        }
    }
}

// MARK: - FileVault

/// `GET /beta/deviceManagement/managedDevices/{id}/getFileVaultKey`
public struct FileVaultKeyResponse: Decodable, Sendable {
    public let value: String?
}

// MARK: - BitLocker

/// `GET /informationProtection/bitlocker/recoveryKeys?$filter=deviceId eq '…'`
public struct BitLockerRecoveryKeyListResponse: Decodable, Sendable {
    public let value: [BitLockerRecoveryKey]
}

/// A BitLocker key record. `key` is present only on a single-key read with
/// `$select=key`.
public struct BitLockerRecoveryKey: Decodable, Sendable {
    public let id: String
    public let createdDateTime: String?
    public let volumeType: String?
    public let deviceId: String?
    public let key: String?

    /// `operatingSystemVolume` → "Operating System Volume".
    public var volumeDisplayName: String {
        guard let volumeType, !volumeType.isEmpty else { return "Volume" }
        let spaced = volumeType.replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
        )
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

// MARK: - Windows LAPS

/// `GET /directory/deviceLocalCredentials/{entraDeviceId}?$select=credentials`
public struct DeviceLocalCredentialInfo: Decodable, Sendable {
    public let id: String?
    public let deviceName: String?
    public let lastBackupDateTime: String?
    public let credentials: [DeviceLocalCredential]?

    /// The credential the device backed up most recently. Earlier entries are
    /// passwords it has already rotated away from.
    public var latestCredential: DeviceLocalCredential? {
        (credentials ?? []).max { ($0.backupDateTime ?? "") < ($1.backupDateTime ?? "") }
    }
}

public struct DeviceLocalCredential: Decodable, Sendable {
    public let accountName: String?
    public let accountSid: String?
    public let backupDateTime: String?
    public let passwordBase64: String?

    /// Graph returns the password base64-encoded UTF-8.
    public var password: String? {
        guard let passwordBase64, let data = Data(base64Encoded: passwordBase64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
