import Foundation

/// The CLI needs the same silent user token that the app injects into its service.
/// Creating the API client alone does not authenticate it.
public enum DevOpsCliSignIn {
    public enum Failure: LocalizedError {
        case notConfigured
        case signInUnavailable

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Azure DevOps is not configured."
            case .signInUnavailable:
                return "Silent Azure DevOps sign-in failed. The command was not run."
            }
        }
    }

    public static func authenticatedService(
        config: FleetMateConfig,
        resolveProject: Bool = true
    ) async throws -> AzureDevOpsService {
        try await authenticatedService(config: config, resolveProject: resolveProject) { tenantId in
            try await DevOpsSsoService(tenantId: tenantId).refreshAccessToken()
        }
    }

    static func authenticatedService(
        config: FleetMateConfig,
        resolveProject: Bool,
        acquireToken: (String?) async throws -> DevOpsSsoResult
    ) async throws -> AzureDevOpsService {
        let service = AzureDevOpsService(config: config)
        guard service.isConfigured else { throw Failure.notConfigured }

        let result: DevOpsSsoResult
        do {
            result = try await acquireToken(config.devopsTenantId ?? config.graphTenantId)
        } catch {
            throw Failure.signInUnavailable
        }
        let lifetime = result.expiresIn ?? 3_600
        guard result.success,
              let token = result.accessToken, !token.isEmpty,
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              lifetime > 60 else {
            throw Failure.signInUnavailable
        }

        service.setBearerToken(token, expiry: Date().addingTimeInterval(TimeInterval(lifetime)))
        if resolveProject, service.resolvedProject.isEmpty {
            _ = try await service.discoverProject()
        }
        return service
    }
}
