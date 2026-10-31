import XCTest
@testable import FleetMateCore

final class TicketPeopleTests: XCTestCase {
    func testPersonAttributesKeepOnlyUidValues() throws {
        let json = """
        {"ID": 1, "Attributes": [
            {"ID": 10, "Name": "Primary Contact", "Value": "00000000-0000-4000-8000-000000000001", "ValueText": "A Person"},
            {"ID": 11, "Name": "Intent", "Value": "28409", "ValueText": "Request"},
            {"ID": 12, "Name": "Workflow Code", "Value": "Order in Progress", "ValueText": "Order in Progress"}
        ]}
        """
        let ticket = try JSONDecoder().decode(TdxTicket.self, from: Data(json.utf8))
        XCTAssertEqual(ticket.personAttributes.map(\.name), ["Primary Contact"])
    }

    func testGroupMemberDecodesNotificationFlag() throws {
        let json = """
        [{"UID": "u1", "FullName": "Member One", "PrimaryEmail": "one@example.invalid",
          "DefaultAccountName": "Admin", "IsGroupNotified": false}]
        """
        let members = try JSONDecoder().decode([TdxPerson].self, from: Data(json.utf8))
        XCTAssertEqual(members.first?.isGroupNotified, false)
        XCTAssertEqual(members.first?.defaultAccountName, "Admin")
    }
}
