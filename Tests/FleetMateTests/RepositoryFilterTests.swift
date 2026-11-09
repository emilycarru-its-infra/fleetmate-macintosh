import XCTest
@testable import FleetMateCore

final class RepositoryFilterTests: XCTestCase {
    private func scope(_ source: PullRequestSource = .azureDevOps, _ container: String = "Platform", _ repository: String? = "tools") -> RepositoryFilterScope {
        .init(source: source, container: container, repository: repository)
    }

    func testDuplicateNamesStaySeparateAcrossProvidersAndContainers() {
        let first = scope(.azureDevOps, "Alpha", "tools")
        let second = scope(.azureDevOps, "Beta", "tools")
        let github = scope(.gitHub, "Alpha", "tools")
        let entries = RepositoryFilterEntry.counts([first, first, second, github], scope: { $0 })
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        let groups = RepositoryFilterProvider.groups(entries)
        XCTAssertEqual(groups.map(\.source), [.azureDevOps, .gitHub])
        XCTAssertEqual(groups.map(\.count), [3, 1])
        XCTAssertEqual(groups[0].containers.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(groups.flatMap(\.containers).flatMap(\.entries).reduce(0) { $0 + $1.count }, 4)
    }

    func testQualifiedSelectionDoesNotMatchSameNameInAnotherScope() {
        let selected = scope(.gitHub, "example", "docs")
        XCTAssertTrue(selected.matches(selected.id, legacyKey: "docs"))
        XCTAssertFalse(scope(.azureDevOps, "example", "docs").matches(selected.id, legacyKey: "docs"))
        XCTAssertFalse(scope(.gitHub, "another", "docs").matches(selected.id, legacyKey: "docs"))
        XCTAssertTrue(selected.matches("docs", legacyKey: "docs"))
        XCTAssertTrue(selected.matches("repository/docs", legacyKey: "repository/docs"))
    }

    func testEscapedIdentitiesRoundTripAndProjectOnlyEntriesRemainDistinct() throws {
        let value = scope(.gitHub, "Owner/One %", "tools/name +%")
        XCTAssertEqual(value.id.split(separator: "/", omittingEmptySubsequences: false).count, 4)
        XCTAssertEqual(try XCTUnwrap(RepositoryFilterScope(id: value.id)), value)
        XCTAssertEqual(scope(.gitHub, "EXAMPLE", "Tools").id, scope(.gitHub, "example", "tools").id)
        let projectOnly = scope(.azureDevOps, "Platform", nil)
        XCTAssertNotEqual(projectOnly.id, scope(.azureDevOps, "Platform", "Project pipelines").id)
        XCTAssertNil(try XCTUnwrap(RepositoryFilterScope(id: projectOnly.id)).repository)
        XCTAssertNil(RepositoryFilterScope(id: "repository/unknown/a/b"))
        XCTAssertNil(RepositoryFilterScope(id: "repository/gitHub/a/%XX"))
    }

    func testHierarchySortsNamesAndPreservesCountsAndLegacyPaths() {
        let rows = [scope(.gitHub, "Example", "zebra"), scope(.gitHub, "Example", "alpha"), scope(.gitHub, "Example", "alpha")]
        let entries = RepositoryFilterEntry.counts(rows, scope: { $0 }, legacyKey: { $0.displayPath })
        let group = RepositoryFilterProvider.groups(entries)[0].containers[0]
        XCTAssertEqual(group.entries.map { $0.scope.repositoryTitle }, ["alpha", "zebra"])
        XCTAssertEqual(group.entries.map(\.count), [2, 1])
        XCTAssertTrue(group.entries[0].scope.matches("Example/alpha", legacyKey: group.entries[0].legacyKey))
        XCTAssertEqual(RepositoryFilterProvider.groups([]).count, 0)
    }
    func testCommitMenusCountCommitsInsteadOfRepositoryRecords() {
        let first = scope(.gitHub, "Example", "alpha")
        let second = scope(.gitHub, "Example", "beta")
        let rows = [(first, 7), (first, 3), (second, 4)]
        let entries = RepositoryFilterEntry.counts(rows, scope: { $0.0 }, weight: { $0.1 })
        XCTAssertEqual(entries.first { $0.id == first.id }?.count, 10)
        XCTAssertEqual(RepositoryFilterProvider.groups(entries).first?.count, 14)
    }

}
