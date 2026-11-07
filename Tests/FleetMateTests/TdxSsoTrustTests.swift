import XCTest
@testable import FleetMateCore

final class TdxSsoTrustTests: XCTestCase {
    private func trust(base: String = "https://example.teamdynamix.com",
                       sp: [String]? = nil, idp: [String]? = nil) -> TdxSsoTrust {
        var config = FleetMateConfig()
        config.tdxBaseUrl = base
        config.tdxSsoServiceProviderHosts = sp
        config.tdxSsoIdentityProviderHosts = idp
        return TdxSsoTrust(config: config)
    }

    func testAssertionGoesOnlyToTheTdxHostOverHttps() {
        let t = trust()
        XCTAssertTrue(t.allowsAssertion(to: URL(string: "https://example.teamdynamix.com/Shibboleth.sso/SAML2/POST")!))
        XCTAssertTrue(t.allowsAssertion(to: URL(string: "https://EXAMPLE.teamdynamix.com/Shibboleth.sso/SAML2/POST")!))
        XCTAssertFalse(t.allowsAssertion(to: URL(string: "http://example.teamdynamix.com/Shibboleth.sso/SAML2/POST")!))
        XCTAssertFalse(t.allowsAssertion(to: URL(string: "https://example.teamdynamix.com.attacker.test/Shibboleth.sso/SAML2/POST")!))
        XCTAssertFalse(t.allowsAssertion(to: URL(string: "https://attacker.test/Shibboleth.sso/SAML2/POST")!))
        XCTAssertFalse(t.allowsAssertion(to: URL(string: "https://user:pw@example.teamdynamix.com/SAML2/POST")!))
        XCTAssertFalse(t.allowsAssertion(to: URL(string: "https://169.254.169.254/SAML2/POST")!))
    }

    func testServiceProviderHostsComeFromSettings() {
        let t = trust(sp: [" sso.example.org ", ""])
        XCTAssertTrue(t.allowsAssertion(to: URL(string: "https://sso.example.org/Shibboleth.sso/SAML2/POST")!))
        XCTAssertFalse(t.allowsAssertion(to: URL(string: "https://other.example.org/Shibboleth.sso/SAML2/POST")!))
    }

    func testOnlyIdentityProvidersMayHandOverAnAssertion() {
        let t = trust(idp: ["idp.example.org"])
        XCTAssertTrue(t.allowsSender(scheme: "https", host: "login.microsoftonline.com"))
        XCTAssertTrue(t.allowsSender(scheme: "https", host: "idp.example.org"))
        XCTAssertFalse(t.allowsSender(scheme: "http", host: "login.microsoftonline.com"))
        XCTAssertFalse(t.allowsSender(scheme: "https", host: "attacker.test"))
        XCTAssertFalse(t.allowsSender(scheme: "https", host: "login.microsoftonline.com.attacker.test"))
    }

    func testTokenComesOnlyFromLoginSso() {
        let expected = URL(string: "https://example.teamdynamix.com/TDWebApi/api/auth/loginSSO")!
        XCTAssertTrue(TdxSsoTrust.isLoginSso(URL(string: "https://example.teamdynamix.com/TDWebApi/api/auth/loginsso")!, expected: expected))
        XCTAssertFalse(TdxSsoTrust.isLoginSso(URL(string: "https://attacker.test/TDWebApi/api/auth/loginSSO")!, expected: expected))
        XCTAssertFalse(TdxSsoTrust.isLoginSso(URL(string: "https://example.teamdynamix.com/Shibboleth.sso/SAML2/POST")!, expected: expected))
        XCTAssertFalse(TdxSsoTrust.isLoginSso(URL(string: "http://example.teamdynamix.com/TDWebApi/api/auth/loginSSO")!, expected: expected))
    }
}
