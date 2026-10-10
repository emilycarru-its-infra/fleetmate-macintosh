import XCTest
@testable import FleetMateCore

final class ModuleEnablementTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "ModuleEnablementTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testNothingStoredMeansEveryModuleOn() {
        let modules = ModuleEnablement.load(from: freshDefaults())
        for module in FleetModule.allCases {
            XCTAssertTrue(modules.isOn(module), "\(module) should default on")
        }
    }

    func testEveryTopLevelModuleIsListed() {
        let names = FleetModule.allCases.map(\.rawValue)
        for expected in ["development", "projects", "devices", "reporting", "manage", "inventory", "identity", "tickets", "enrollment"] {
            XCTAssertTrue(names.contains(expected), "\(expected) missing")
        }
    }

    func testRoundTripKeepsDisabledSet() {
        let defaults = freshDefaults()
        var modules = ModuleEnablement()
        modules.set(.tickets, on: false)
        modules.set(.enrollment, on: false)
        modules.save(to: defaults)
        let loaded = ModuleEnablement.load(from: defaults)
        XCTAssertEqual(loaded.disabled, [.tickets, .enrollment])
        XCTAssertEqual(defaults.string(forKey: ModuleEnablement.defaultsKey), "tickets,enrollment")
    }

    func testSwitchingEverythingBackOnClearsTheKey() {
        let defaults = freshDefaults()
        var modules = ModuleEnablement(disabled: [.reporting])
        modules.save(to: defaults)
        modules.set(.reporting, on: true)
        modules.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: ModuleEnablement.defaultsKey))
    }

    func testLegacyNamesAndUnknownValuesAreTolerated() {
        let modules = ModuleEnablement(storedValue: "Apple, snipe,tdx\nsomethingNew,,")
        XCTAssertEqual(modules.disabled, [.enrollment, .inventory, .tickets])
    }

    func testModulesWithoutConfigurationStayHiddenEvenWhenOn() {
        let config = FleetMateConfig()
        let modules = ModuleEnablement()
        XCTAssertFalse(modules.isActive(.inventory, config: config))
        XCTAssertFalse(modules.isActive(.tickets, config: config))
        XCTAssertTrue(modules.isActive(.development, config: config))
        XCTAssertTrue(modules.isActive(.reporting, config: config))
    }

    func testSwitchedOffModuleHidesEvenWhenConfigured() {
        var config = FleetMateConfig()
        config.snipeUrl = "https://assets.example.com"
        config.snipeApiKey = "key"
        var modules = ModuleEnablement()
        XCTAssertTrue(modules.isActive(.inventory, config: config))
        modules.set(.inventory, on: false)
        XCTAssertFalse(modules.isActive(.inventory, config: config))
    }

    func testSummariesNameNoProducts() {
        let products = ["Snipe", "TeamDynamix", "TDX", "Intune", "Entra", "Azure", "GitHub", "Microsoft", "Apple School", "Business Manager"]
        for module in FleetModule.allCases {
            for product in products {
                XCTAssertFalse(module.summary.contains(product), "\(module) summary names \(product)")
                XCTAssertFalse(module.title.contains(product), "\(module) title names \(product)")
            }
        }
    }
}

final class AuthProviderGroupingTests: XCTestCase {
    func testElevationAndDevOpsGroupUnderTheAzSignIn() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["FLEETMATE_GRAPH_TRANSPORT"]?.lowercased() == "direct")
        let config = FleetMateConfig()
        let groups = AuthProviderGrouping.group([.intune, .graph, .devops, .github, .entra], config: config)
        XCTAssertEqual(groups.map(\.provider), [.azureCli, .githubCli])
        XCTAssertEqual(groups[0].systems, [.intune, .graph, .devops, .entra])
        XCTAssertEqual(groups[1].systems, [.github])
    }

    func testElevationDomains() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["FLEETMATE_GRAPH_TRANSPORT"]?.lowercased() == "direct")
        let config = FleetMateConfig()
        XCTAssertEqual(AuthProviderGrouping.elevationDomain(for: .intune, config: config), .devices)
        XCTAssertEqual(AuthProviderGrouping.elevationDomain(for: .graph, config: config), .devices)
        XCTAssertEqual(AuthProviderGrouping.elevationDomain(for: .entra, config: config), .identity)
        XCTAssertNil(AuthProviderGrouping.elevationDomain(for: .devops, config: config))
    }

    func testSnipeFollowsItsAuthMethod() {
        var config = FleetMateConfig()
        config.snipeOidcAudience = "api://inventory"
        XCTAssertEqual(AuthProviderGrouping.provider(for: .snipe, config: config), .browserSso)
        config.snipeOidcAudience = nil
        config.snipeSsoEnabled = true
        XCTAssertEqual(AuthProviderGrouping.provider(for: .snipe, config: config), .browserSso)
        config.snipeAuthMethod = .apiKey
        XCTAssertEqual(AuthProviderGrouping.provider(for: .snipe, config: config), .storedCredential)
    }

    func testTicketsServiceAccountIsAStoredCredential() {
        var config = FleetMateConfig()
        config.tdxAuthMethod = .serviceAccount
        XCTAssertEqual(AuthProviderGrouping.provider(for: .tdx, config: config), .storedCredential)
        config.tdxAuthMethod = .browserSSO
        XCTAssertEqual(AuthProviderGrouping.provider(for: .tdx, config: config), .browserSso)
    }

    func testSingleSignOnListsFirst() {
        XCTAssertEqual(CredentialProvider.allCases.first, .browserSso)
    }

    func testDisplayStatusNeverLeavesConfiguredAsFinal() {
        XCTAssertEqual(AuthDisplayStatus(state: .configured, lastChecked: nil), .checking(nil))
        XCTAssertEqual(AuthDisplayStatus(state: .configured, lastChecked: Date()), .needsSignIn)
        XCTAssertEqual(AuthDisplayStatus(state: .valid(user: nil, expiry: nil), lastChecked: Date()), .valid)
        XCTAssertEqual(AuthDisplayStatus(state: .failed(message: "boom"), lastChecked: Date()), .failed("boom"))
    }

    func testGroupSummary() {
        XCTAssertEqual(AuthDisplayStatus.summary([.valid, .valid]).label, "All valid")
        XCTAssertEqual(AuthDisplayStatus.summary([.valid, .checking(nil)]).tone, .neutral)
        let mixed = AuthDisplayStatus.summary([.valid, .failed("x"), .needsSignIn, .valid, .valid])
        XCTAssertEqual(mixed.label, "2 of 5 need attention")
        XCTAssertEqual(mixed.tone, .attention)
        XCTAssertEqual(AuthDisplayStatus.summary([.notConfigured]).tone, .inactive)
    }

    func testEmptyProvidersAreLeftOut() {
        let groups = AuthProviderGrouping.group([.gitea], config: FleetMateConfig())
        XCTAssertEqual(groups.map(\.provider), [.storedCredential])
    }

    func testParsesAzAccount() {
        let json = #"{"name":"Sub One","tenantId":"t-1","user":{"name":"admin@example.com","type":"user"}}"#
        let account = CliAccountProbe.parseAzAccount(json)
        XCTAssertEqual(account?.user, "admin@example.com")
        XCTAssertEqual(account?.tenantId, "t-1")
        XCTAssertEqual(account?.subscription, "Sub One")
        XCTAssertEqual(account?.isServicePrincipal, false)
        XCTAssertNil(CliAccountProbe.parseAzAccount("Please run 'az login' to setup account."))
    }

    func testParsesGhStatus() {
        let modern = "github.com\n  ✓ Logged in to github.com account octocat (keyring)\n  - Active account: true"
        XCTAssertEqual(CliAccountProbe.parseGhStatus(modern)?.user, "octocat")
        let older = "✓ Logged in to github.com as hubot (oauth_token)"
        XCTAssertEqual(CliAccountProbe.parseGhStatus(older)?.user, "hubot")
        XCTAssertNil(CliAccountProbe.parseGhStatus("You are not logged into any GitHub hosts."))
    }
}

final class ElevationSettingsTests: XCTestCase {
    func testNoImageIsBuiltIn() {
        let settings = ElevationSettings(config: FleetMateConfig())
        XCTAssertNil(settings.image)
        XCTAssertEqual(settings.sessionsResourceGroup, ElevationSettings.defaultResourceGroup)
        XCTAssertEqual(settings.identityResourceGroup, settings.sessionsResourceGroup)
    }

    func testConfiguredValuesWin() {
        var config = FleetMateConfig()
        config.elevationImage = " registry.example.com/elevation-session:latest "
        config.elevationResourceGroup = "Sessions"
        config.elevationTranscriptAccount = "transcripts"
        let settings = ElevationSettings(config: config)
        XCTAssertEqual(settings.image, "registry.example.com/elevation-session:latest")
        XCTAssertEqual(settings.sessionsResourceGroup, "Sessions")
        XCTAssertEqual(settings.identityResourceGroup, "Sessions")
        XCTAssertEqual(settings.transcriptAccount, "transcripts")
    }

    func testErrorsCarryTheirMessage() {
        let error: Error = ElevationError.createFailed("(InaccessibleImage) The image could not be pulled.")
        XCTAssertTrue(error.localizedDescription.contains("InaccessibleImage"))
        XCTAssertFalse(error.localizedDescription.contains("error 1"))
    }

    func testAzMessageDropsWarnings() {
        let message = ElevationSession.azMessage((out: "", err: "WARNING: preview\nERROR: (AuthorizationFailed) denied\n", code: 1))
        XCTAssertEqual(message, "ERROR: (AuthorizationFailed) denied")
        XCTAssertEqual(ElevationSession.azMessage((out: "", err: "", code: 3)), "az exited with code 3")
    }

    func testTransitionalStatesAreWaitedOn() {
        XCTAssertTrue(ElevationSession.isTransitional("Pending"))
        XCTAssertTrue(ElevationSession.isTransitional("Creating"))
        XCTAssertFalse(ElevationSession.isTransitional("Running"))
        XCTAssertFalse(ElevationSession.isTransitional("Terminated"))
        XCTAssertFalse(ElevationSession.isTransitional(""))
    }

    func testContainerHoldsWithAzeHoldWhenTheImageHasIt() {
        let line = ElevationSession.containerCommandLine(clientId: "cid", ttlSeconds: 3600, idleSeconds: 1800)
        XCTAssertTrue(line.contains("--client-id cid"))
        XCTAssertTrue(line.contains("exec aze-hold 3600 1800"))
        XCTAssertTrue(line.hasSuffix("sleep 3600'"))
    }
}

final class AppVersionDisplayTests: XCTestCase {
    func testStampedReleaseJoinsDateAndTime() {
        XCTAssertEqual(AppVersionDisplay.string(short: "2026.10.10", build: "0158", commit: "abc1234"), "2026.10.10.0158")
    }

    func testUnstampedBuildReadsDev() {
        XCTAssertEqual(AppVersionDisplay.string(short: "1.0.0", build: "1.0.0", commit: "abc1234"), "dev (abc1234)")
        XCTAssertEqual(AppVersionDisplay.string(short: "1.0.0", build: "1.0.0", commit: nil), "dev")
    }
}
