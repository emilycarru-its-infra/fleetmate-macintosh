import XCTest
@testable import FleetMateCore

final class GitHubProjectBoardTests: XCTestCase {
    private let statusField = GitHubProjectField(
        id: "f1", name: "Status", dataType: "SINGLE_SELECT",
        options: [
            GitHubProjectSelectOption(id: "o1", name: "Todo", color: "GRAY"),
            GitHubProjectSelectOption(id: "o2", name: "In Progress", color: "YELLOW"),
            GitHubProjectSelectOption(id: "o3", name: "Done", color: "GREEN"),
        ]
    )

    private func item(_ id: String, title: String, status: String?, number: Int? = nil, repo: String? = nil) -> GitHubProjectItem {
        let values = status.map {
            [GitHubProjectFieldValue(fieldId: "f1", fieldName: "Status", dataType: "SINGLE_SELECT", singleSelectValue: $0)]
        } ?? []
        if let number {
            return GitHubProjectItem(
                id: id, type: "ISSUE",
                content: GitHubProjectItemContent(id: "c\(id)", number: number, title: title, repository: repo),
                fieldValues: values
            )
        }
        return GitHubProjectItem(id: id, type: "DRAFT_ISSUE",
                                 draftContent: GitHubProjectDraftContent(title: title), fieldValues: values)
    }

    func testColumnsFollowStatusOptionOrder() {
        let columns = GitHubProjectBoard.columns(
            items: [item("1", title: "A", status: "Done"), item("2", title: "B", status: "todo")],
            statusField: statusField
        )
        XCTAssertEqual(columns.map(\.name), ["Todo", "In Progress", "Done"])
        XCTAssertEqual(columns[0].items.map(\.id), ["2"], "status match is case-insensitive")
        XCTAssertEqual(columns[2].items.map(\.id), ["1"])
        XCTAssertTrue(columns[1].items.isEmpty, "empty status columns stay, like GitHub's board")
    }

    func testUnsetOrUnknownStatusGoesToNoStatus() {
        let columns = GitHubProjectBoard.columns(
            items: [item("1", title: "A", status: nil), item("2", title: "B", status: "Archived option")],
            statusField: statusField
        )
        XCTAssertEqual(columns.last?.name, GitHubProjectBoard.noStatus)
        XCTAssertEqual(columns.last?.items.map(\.id), ["1", "2"])
    }

    func testNoStatusColumnOmittedWhenEmpty() {
        let columns = GitHubProjectBoard.columns(items: [item("1", title: "A", status: "Todo")], statusField: statusField)
        XCTAssertFalse(columns.contains { $0.name == GitHubProjectBoard.noStatus })
    }

    func testWithoutStatusFieldEverythingIsNoStatus() {
        let columns = GitHubProjectBoard.columns(items: [item("1", title: "A", status: "Todo")], statusField: nil)
        XCTAssertEqual(columns.map(\.name), [GitHubProjectBoard.noStatus])
    }

    func testSearchMatchesTitleNumberAndRepository() {
        let items = [
            item("1", title: "Fix login", status: "Todo", number: 42, repo: "owner/app"),
            item("2", title: "Write docs", status: "Todo", number: 7, repo: "owner/site"),
            item("3", title: "Draft idea", status: "Todo"),
        ]
        func ids(_ q: String) -> [String] {
            GitHubProjectBoard.columns(items: items, statusField: statusField, search: q).flatMap { $0.items.map(\.id) }
        }
        XCTAssertEqual(ids("login"), ["1"])
        XCTAssertEqual(ids("#7"), ["2"])
        XCTAssertEqual(ids("42"), ["1"])
        XCTAssertEqual(ids("site"), ["2"])
        XCTAssertEqual(ids("  "), ["1", "2", "3"])
    }

    func testDisplayTitleFallsBackToDraft() {
        XCTAssertEqual(item("1", title: "Draft idea", status: nil).displayTitle, "Draft idea")
        XCTAssertTrue(item("1", title: "x", status: nil).isDraft)
    }
}
