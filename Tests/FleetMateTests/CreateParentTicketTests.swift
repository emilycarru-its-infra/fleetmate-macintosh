import XCTest
@testable import FleetMateCore

final class CreateParentTicketTests: XCTestCase {

    func testParentCarriesTheChildsQueueFields() throws {
        let fields: [String: Any] = [
            "ID": 42, "Title": "Printer offline", "TypeID": 7, "Classification": 46,
            "FormID": 3, "AccountID": 11, "PriorityID": 20, "SourceID": 8, "ServiceID": 5,
            "RequestorUid": "req-uid", "ResponsibleUid": "resp-uid", "ResponsibleGroupID": 9,
            "ParentID": 0,
        ]
        let child = try JSONDecoder().decode(TdxTicket.self, from: JSONSerialization.data(withJSONObject: fields))

        let request = CreateTicketRequest.parent(of: child, title: "  Printers offline in one building  ")

        XCTAssertEqual(request.title, "Printers offline in one building")
        XCTAssertEqual(request.typeId, 7)
        XCTAssertEqual(request.formId, 3)
        XCTAssertEqual(request.accountId, 11)
        XCTAssertEqual(request.priorityId, 20)
        XCTAssertEqual(request.sourceId, 8)
        XCTAssertEqual(request.serviceId, 5)
        XCTAssertEqual(request.requestorUid, "req-uid")
        XCTAssertEqual(request.responsibleUid, "resp-uid")
        XCTAssertEqual(request.responsibleGroupId, 9)
        XCTAssertNil(request.parentId, "the new parent must not itself get a parent")
        XCTAssertEqual(request.description, "Parent of ticket 42.")
    }
}
