import XCTest
@testable import FleetMateCore

/// The TDX identity check refuses a sign-in with no address to compare
/// against, so the device must yield one wherever it holds it.
final class SignedInAddressTests: XCTestCase {
    private let enrolled = #"""
    User Configuration:
     {
      "kerberosStatus" : [
        {
          "realm" : "KERBEROS.MICROSOFTONLINE.COM",
          "ticketKeyPath" : "tgt_cloud",
          "upn" : "adoe\\@EXAMPLE.EDU@KERBEROS.MICROSOFTONLINE.COM"
        },
        {
          "realm" : "EXAMPLE.EDU",
          "ticketKeyPath" : "tgt_ad",
          "upn" : "ADoe@EXAMPLE.EDU"
        }
      ],
      "userLoginConfiguration" : {
        "loginUserName" : "a***e@example.edu"
      }
    }
    """#

    func testTheOnPremisesTicketComesFirst() {
        XCTAssertEqual(SignedInAddress.fromPlatformSso(enrolled), "adoe@example.edu")
    }

    func testACloudOnlyMacUsesTheCloudTicket() {
        let cloudOnly = #"""
          "kerberosStatus" : [
            {
              "ticketKeyPath" : "tgt_cloud",
              "upn" : "adoe\\@EXAMPLE.EDU@KERBEROS.MICROSOFTONLINE.COM"
            }
          ],
          "loginUserName" : "a***e@example.edu"
        """#
        XCTAssertEqual(SignedInAddress.fromPlatformSso(cloudOnly), "adoe@example.edu")
    }

    func testAMaskedLoginNameIsNotAnAddress() {
        XCTAssertNil(SignedInAddress.fromPlatformSso(#""loginUserName" : "a***e@example.edu""#))
        XCTAssertEqual(SignedInAddress.fromPlatformSso(#""loginUserName" : "ADoe@example.edu""#), "adoe@example.edu")
    }

    func testNothingEnrolledGivesNothing() {
        XCTAssertNil(SignedInAddress.fromPlatformSso("Device Configuration:\n null\n"))
    }

    func testTheKerberosExtensionPrincipalIsRead() throws {
        let json = try XCTUnwrap(#"{"realm":"EXAMPLE.EDU","upn":"ADoe@EXAMPLE.EDU"}"#.data(using: .utf8))
        XCTAssertEqual(SignedInAddress.fromKerberosRealm(json), "adoe@example.edu")
    }

    func testNormalizedRejectsWhatIsNotAnAddress() {
        XCTAssertNil(SignedInAddress.normalized(nil))
        XCTAssertNil(SignedInAddress.normalized(""))
        XCTAssertNil(SignedInAddress.normalized(#"EXAMPLE\adoe"#))
        XCTAssertNil(SignedInAddress.normalized("a***e@example.edu"))
        XCTAssertEqual(SignedInAddress.normalized(" ADoe@Example.EDU "), "adoe@example.edu")
    }
}
