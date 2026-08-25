import XCTest
@testable import FleetMateCore

/// The audit filter.
///
/// `directoryAudits` answers a malformed `$filter` with an empty collection
/// rather than an error, and "no entries" is exactly what someone investigating
/// a deletion is afraid of seeing. So the filter is built by a pure function and
/// asserted here, instead of being trusted because a call came back.
final class DirectoryAuditFilterTests: XCTestCase {

    /// 2026-08-24T21:00:00Z
    private var now: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 24
        components.hour = 21
        components.minute = 0
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    func testNoConstraintsMeansNoFilter() {
        // Not an empty string: an empty $filter is a query parameter Graph still
        // has to interpret, and it rejects it.
        XCTAssertNil(DirectoryAuditQuery.filter(target: nil, activity: nil, days: 0, now: now))
    }

    func testDaysBecomesAnIso8601Floor() {
        let filter = DirectoryAuditQuery.filter(target: nil, activity: nil, days: 7, now: now)
        XCTAssertEqual(filter, "activityDateTime ge 2026-08-17T21:00:00Z")
    }

    func testGuidTargetMatchesOnObjectId() {
        let filter = DirectoryAuditQuery.filter(
            target: "2592274D-6C10-4DAA-904E-49A47D94E5B0", activity: nil, days: 0, now: now)
        XCTAssertEqual(
            filter,
            "targetResources/any(t: t/id eq '2592274D-6C10-4DAA-904E-49A47D94E5B0')")
    }

    func testNonGuidTargetMatchesOnDisplayName() {
        // Whoever is investigating usually has the name, not the id -- the id
        // died with the object.
        let filter = DirectoryAuditQuery.filter(
            target: "Devices-Shared-Kiosk-Signage-A2003", activity: nil, days: 0, now: now)
        XCTAssertEqual(
            filter,
            "targetResources/any(t: t/displayName eq 'Devices-Shared-Kiosk-Signage-A2003')")
    }

    func testClausesCombineWithAnd() {
        let filter = DirectoryAuditQuery.filter(
            target: "Some-Group", activity: "Delete group", days: 30, now: now)
        XCTAssertEqual(
            filter,
            "activityDateTime ge 2026-07-25T21:00:00Z and "
                + "activityDisplayName eq 'Delete group' and "
                + "targetResources/any(t: t/displayName eq 'Some-Group')")
    }

    func testQuotesInAValueAreEscaped() {
        // An unescaped apostrophe terminates the OData string literal, and the
        // resulting filter is either rejected or silently matches nothing.
        let filter = DirectoryAuditQuery.filter(
            target: "O'Brien's Laptop", activity: nil, days: 0, now: now)
        XCTAssertEqual(
            filter,
            "targetResources/any(t: t/displayName eq 'O''Brien''s Laptop')")
    }
}

/// The audit actor, which is a union: an entry names a user or an application,
/// never both. Automation is always the application, and that is precisely the
/// case worth identifying.
final class DirectoryAuditActorTests: XCTestCase {

    private func decode(_ json: String) throws -> DirectoryAuditEvent {
        try JSONDecoder().decode(DirectoryAuditEvent.self, from: Data(json.utf8))
    }

    func testUserActorPrefersTheUpn() throws {
        let event = try decode(#"""
        {
          "id": "1",
          "activityDisplayName": "Update group",
          "initiatedBy": { "user": { "displayName": "Ada Lovelace", "userPrincipalName": "ada@example.edu" } }
        }
        """#)

        XCTAssertEqual(event.actor, "ada@example.edu")
        XCTAssertFalse(event.actorIsApplication)
    }

    func testApplicationActorIsFlagged() throws {
        let event = try decode(#"""
        {
          "id": "2",
          "activityDisplayName": "Delete group",
          "initiatedBy": { "app": { "displayName": "Some Lifecycle Service" } }
        }
        """#)

        XCTAssertEqual(event.actor, "Some Lifecycle Service")
        XCTAssertTrue(event.actorIsApplication)
    }

    func testAbsentInitiatorIsUnknownRatherThanBlank() throws {
        // Rendering a blank cell would read as "nobody did this".
        let event = try decode(#"{ "id": "3" }"#)
        XCTAssertEqual(event.actor, "unknown")
        XCTAssertFalse(event.actorIsApplication)
    }

    func testTargetsJoinAndEmptyReadsAsADash() throws {
        let withTargets = try decode(#"""
        {
          "id": "4",
          "targetResources": [ { "displayName": "Group-A" }, { "id": "id-only" } ]
        }
        """#)
        XCTAssertEqual(withTargets.targets, "Group-A, id-only")

        let bare = try decode(#"{ "id": "5" }"#)
        XCTAssertEqual(bare.targets, "-")
    }
}

/// Settings Catalog matching.
///
/// Graph offers neither `$search` nor a useful `$filter` on this collection, so
/// the match runs locally and is the whole feature rather than a convenience on
/// top of a server-side query.
final class SettingsCatalogMatchTests: XCTestCase {

    private func decode(_ json: String) throws -> SettingsCatalogDefinition {
        try JSONDecoder().decode(SettingsCatalogDefinition.self, from: Data(json.utf8))
    }

    func testExactIdMatchesItself() throws {
        // The commonest use: someone holds an id Graph rejected and wants to know
        // whether it exists at all.
        let setting = try decode(
            #"{ "id": "device_vendor_msft_policy_config_windowslogon_hidefastuserswitching" }"#)
        XCTAssertTrue(setting.matches(query: setting.id))
    }

    func testMatchingIsCaseInsensitive() throws {
        let setting = try decode(#"{ "id": "device_vendor_msft_windowslogon" }"#)
        XCTAssertTrue(setting.matches(query: "WindowsLogon"))
    }

    func testProseFieldsAreSearchedToo() throws {
        let setting = try decode(#"""
        { "id": "some_opaque_id", "displayName": "Hide Lock Screen Clock", "description": "Hides the clock." }
        """#)
        XCTAssertTrue(setting.matches(query: "lock screen"))
        XCTAssertTrue(setting.matches(query: "clock"))
    }

    func testKeywordsAreSearched() throws {
        let setting = try decode(#"{ "id": "x", "keywords": ["kiosk"] }"#)
        XCTAssertTrue(setting.matches(query: "kiosk"))
    }

    func testEveryTermMustAppear() throws {
        // A multi-word query has to narrow. Matching on any term would return
        // most of a catalog with tens of thousands of entries.
        let setting = try decode(#"{ "id": "x", "displayName": "Hide Lock Screen Clock" }"#)
        XCTAssertTrue(setting.matches(query: "hide clock"))
        XCTAssertFalse(setting.matches(query: "hide taskbar"))
    }

    func testEmptyQueryMatchesEverything() throws {
        // `fleetmate intune settings --platform windows10` with no term is a
        // browse, not a search.
        let setting = try decode(#"{ "id": "anything" }"#)
        XCTAssertTrue(setting.matches(query: nil))
        XCTAssertTrue(setting.matches(query: "   "))
    }

    func testOdataTypeDecodesAndReducesToAKind() throws {
        // The @odata.type key needs its CodingKey to survive decoding, and the
        // value shape is part of the answer: a right id with a wrong shape is
        // rejected just as firmly as a bad id.
        let setting = try decode(#"""
        { "id": "x", "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition" }
        """#)
        XCTAssertEqual(setting.kind, "Choice")
    }

    func testNextLinkDecodesFromItsOdataKey() throws {
        // Paging silently stopping after one page would quietly truncate every
        // search of a catalog this size.
        let page = try JSONDecoder().decode(
            SettingsCatalogListResponse.self,
            from: Data(#"{ "value": [], "@odata.nextLink": "https://example/next" }"#.utf8))
        XCTAssertEqual(page.nextLink, "https://example/next")
    }
}
