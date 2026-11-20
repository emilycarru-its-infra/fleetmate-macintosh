import XCTest
@testable import FleetMateCore

final class LightboxHistoryTests: XCTestCase {
    private let root = FleetMateLink.workItem(id: 7264)
    private let child = FleetMateLink.workItem(id: 7265)
    private let pr = FleetMateLink.pullRequest(.azureDevOps(project: "Platform", repo: "Fleet"), number: 42)
    private let commit = FleetMateLink.commit(.gitHub(owner: "octo", repo: "tool"), sha: "0a1b2c3d")

    func testStartsAtTheRootWithNowhereToGo() {
        let history = LightboxHistory(root)
        XCTAssertEqual(history.entries, [root])
        XCTAssertEqual(history.current, root)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testPushAddsACrumbAndMovesToIt() {
        var history = LightboxHistory(root)
        history.push(child)
        history.push(pr)
        XCTAssertEqual(history.entries, [root, child, pr])
        XCTAssertEqual(history.current, pr)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testPushingThePlaceAlreadyShownChangesNothing() {
        var history = LightboxHistory(root)
        history.push(child)
        history.push(child)
        XCTAssertEqual(history.entries, [root, child])
        XCTAssertEqual(history.index, 1)
    }

    func testBackToACrumbKeepsWhatLiesAhead() {
        var history = LightboxHistory(root)
        history.push(child)
        history.push(pr)
        history.go(to: 0)
        XCTAssertEqual(history.current, root)
        XCTAssertEqual(history.entries, [root, child, pr])
        XCTAssertTrue(history.canGoForward)
        XCTAssertFalse(history.canGoBack)
    }

    func testBackAndForwardStepOnePlace() {
        var history = LightboxHistory(root)
        history.push(child)
        history.push(pr)
        history.back()
        XCTAssertEqual(history.current, child)
        history.back()
        XCTAssertEqual(history.current, root)
        history.back()
        XCTAssertEqual(history.current, root, "Back at the root stays there")
        history.forward()
        history.forward()
        XCTAssertEqual(history.current, pr)
        history.forward()
        XCTAssertEqual(history.current, pr, "Forward at the end stays there")
    }

    func testFollowingALinkAfterGoingBackDropsTheForwardPlaces() {
        var history = LightboxHistory(root)
        history.push(child)
        history.push(pr)
        history.go(to: 0)
        history.push(commit)
        XCTAssertEqual(history.entries, [root, commit])
        XCTAssertFalse(history.canGoForward)
    }

    func testGoToAnUnknownCrumbIsIgnored() {
        var history = LightboxHistory(root)
        history.push(child)
        history.go(to: 5)
        history.go(to: -1)
        XCTAssertEqual(history.current, child)
    }

    func testWhichLinksOpenInTheLightbox() {
        XCTAssertTrue(root.opensInLightbox)
        XCTAssertTrue(FleetMateLink.gitHubIssue(owner: "octo", repo: "tool", number: 1).opensInLightbox)
        XCTAssertTrue(pr.opensInLightbox)
        XCTAssertTrue(commit.opensInLightbox)
        XCTAssertTrue(FleetMateLink.azureDevOpsRun(project: "Platform", runId: 1).opensInLightbox)
        XCTAssertTrue(FleetMateLink.gitHubRun(owner: "octo", repo: "tool", runId: 1).opensInLightbox)
        XCTAssertFalse(FleetMateLink.device(id: "abc").opensInLightbox)
        XCTAssertFalse(FleetMateLink.ticket(id: 1).opensInLightbox)
        XCTAssertFalse(FleetMateLink.user(id: "someone@example.org").opensInLightbox)
    }
}

final class AgentDockLinkRuleTests: XCTestCase {
    func testAnInAppLinkHidesTheShowingDock() {
        XCTAssertTrue(AgentDockLinkRule.hidesDock(dockShowing: true, target: .inApp))
    }

    func testAHiddenDockStaysHidden() {
        XCTAssertFalse(AgentDockLinkRule.hidesDock(dockShowing: false, target: .inApp))
        XCTAssertFalse(AgentDockLinkRule.hidesDock(dockShowing: false, target: .outsideApp))
    }

    func testABrowserLinkLeavesTheDockUp() {
        XCTAssertFalse(AgentDockLinkRule.hidesDock(dockShowing: true, target: .outsideApp))
    }
}
