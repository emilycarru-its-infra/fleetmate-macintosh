import XCTest
@testable import FleetMateCore

final class DevOpsCliSignInTests: XCTestCase {
    func testSetsUsableTokenAndPreservesConfiguredProject() async throws {
        var config = Self.config()
        config.devopsTenantId = "tenant-placeholder"
        let service = try await DevOpsCliSignIn.authenticatedService(config: config, resolveProject: true) { tenant in
            XCTAssertEqual(tenant, "tenant-placeholder")
            return .success(accessToken: "synthetic-token", expiresIn: 3_600)
        }
        XCTAssertTrue(service.hasValidToken)
        XCTAssertEqual(service.resolvedProject, "Example")
    }

    func testUnconfiguredServiceDoesNotAttemptAuthentication() async {
        var called = false
        do {
            _ = try await DevOpsCliSignIn.authenticatedService(config: FleetMateConfig(), resolveProject: false) { _ in
                called = true
                return .success(accessToken: "synthetic-token")
            }
            XCTFail("An unconfigured service must be refused")
        } catch {
            XCTAssertTrue(error is DevOpsCliSignIn.Failure)
        }
        XCTAssertFalse(called)
    }

    func testProviderConfigurationAndSharedTenantAreUsed() async throws {
        var config = FleetMateConfig()
        config.graphTenantId = "shared-tenant-placeholder"
        config.tasks = TasksConfig(providers: TaskProvidersConfig(
            azdevops: AzureDevOpsProviderConfig(organization: "provider-example", project: "Provider")))
        let service = try await DevOpsCliSignIn.authenticatedService(config: config, resolveProject: true) { tenant in
            XCTAssertEqual(tenant, "shared-tenant-placeholder")
            return .success(accessToken: "synthetic-token")
        }
        XCTAssertTrue(service.hasValidToken)
        XCTAssertTrue(service.baseUrl.hasSuffix("/provider-example"))
        XCTAssertEqual(service.resolvedProject, "Provider")
    }

    func testFailedSignInDoesNotReturnAnAuthenticatedClientOrExposeProviderDetails() async {
        do {
            _ = try await DevOpsCliSignIn.authenticatedService(config: Self.config(), resolveProject: false) { _ in
                .failure("provider-private-detail")
            }
            XCTFail("A failed sign-in must be refused")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("provider-private-detail"))
            XCTAssertTrue(error is DevOpsCliSignIn.Failure)
        }
    }

    func testUnusableTokensAndExpiredLifetimesAreRefused() async {
        let results: [DevOpsSsoResult] = [
            .success(accessToken: ""),
            .success(accessToken: " \n"),
            .success(accessToken: "token\r\nheader"),
            .success(accessToken: "synthetic-token", expiresIn: 0),
            .success(accessToken: "synthetic-token", expiresIn: 60),
        ]
        for result in results {
            do {
                _ = try await DevOpsCliSignIn.authenticatedService(config: Self.config(), resolveProject: false) { _ in result }
                XCTFail("An unusable token must not reach an API request")
            } catch {
                XCTAssertTrue(error is DevOpsCliSignIn.Failure)
            }
        }
    }

    func testThrownAuthenticationFailureIsReportedWithoutRawDetails() async {
        do {
            _ = try await DevOpsCliSignIn.authenticatedService(config: Self.config(), resolveProject: false) { _ in
                throw NSError(domain: "provider-private-detail", code: 1)
            }
            XCTFail("Authentication errors must be refused")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("provider-private-detail"))
            XCTAssertTrue(error is DevOpsCliSignIn.Failure)
        }
    }

    private static func config() -> FleetMateConfig {
        var config = FleetMateConfig()
        config.devopsOrganization = "example"
        config.devopsProject = "Example"
        return config
    }
}
