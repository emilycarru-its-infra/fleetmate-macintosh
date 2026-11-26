import XCTest
@testable import FleetMateCore

final class TicketEmailTemplateTests: XCTestCase {

    func testVariablesEscapeAndTripleBracesDoNot() {
        let out = MustacheRenderer.render("{{Title}} | {{{Body}}}", ["Title": "a < b", "Body": "<b>hi</b>"])
        XCTAssertEqual(out, "a &lt; b | <b>hi</b>")
    }

    func testSectionsShowOnlyWithAValue() {
        let template = "{{#Description}}D: {{{Description}}}{{/Description}}{{^Description}}none{{/Description}}"
        XCTAssertEqual(MustacheRenderer.render(template, ["Description": "<p>x</p>"]), "D: <p>x</p>")
        XCTAssertEqual(MustacheRenderer.render(template, ["Description": "  "]), "none")
        XCTAssertEqual(MustacheRenderer.render(template, [:]), "none")
    }

    func testAttributeSectionsScopeTheirNameAndValue() {
        let template = "{{#Attribute1}}{{Name}}={{Value}}{{/Attribute1}}{{#Attribute2}}hidden{{/Attribute2}}"
        let out = MustacheRenderer.render(template, ["Attribute1": ["Name": "Room", "Value": "C4245"]])
        XCTAssertEqual(out, "Room=C4245")
    }

    func testCommentEmailFillsTheInstalledTemplate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("115")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[Ticket {{ID}}] {{UpdateCreatedUserFullName}}: {{{UpdateText}}}{{#ServiceName}} ({{ServiceName}}){{/ServiceName}}"
            .write(to: folder.appendingPathComponent("ticket_comment_added_ticketing_user.html"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let item = TicketInboxItem(id: 1, ticketId: 42, ticketTitle: "Printer", author: "Jim",
                                   authorEmail: nil, body: "<p>Fixed</p>", createdDate: "2026-11-24T10:00:00Z",
                                   isPrivate: false)
        let templates = TicketEmailTemplates(root: root)
        XCTAssertEqual(templates.commentEmail(item: item, ticket: nil, appId: 115, ticketUrl: nil, dateText: "today"),
                       "[Ticket 42] Jim: <p>Fixed</p>")
        XCTAssertNil(templates.commentEmail(item: item, ticket: nil, appId: 999, ticketUrl: nil, dateText: "today"))
    }
}
