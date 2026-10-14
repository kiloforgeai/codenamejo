import XCTest
@testable import CodenameJo

// coverage-target: CodenameJo/Services/AppInfo.swift

/// `AppInfo` is what stamps a `ConversationRecord` with the build that took the call, so
/// its two halves have to stay separable and its OS string has to be sortable rather than
/// prose. Values are checked against the process the test runs in, not against literals
/// that would go stale every release.
final class AppInfoVersionTests: XCTestCase {

    func testTheDisplayVersionIsTheTwoHalvesAndNothingElse() {
        XCTAssertEqual(AppInfo.appVersion, "\(AppInfo.shortVersion) (\(AppInfo.buildNumber))")
        XCTAssertFalse(AppInfo.shortVersion.isEmpty)
        XCTAssertFalse(AppInfo.buildNumber.isEmpty)
        // The halves are what a dashboard groups by, so neither may carry the other's
        // punctuation back in.
        XCTAssertFalse(AppInfo.shortVersion.contains("("))
        XCTAssertFalse(AppInfo.buildNumber.contains("("))
    }

    /// `operatingSystemVersionString` comes back as "Version 26.0 (Build 23A344)". This
    /// must be the sortable form, and must drop a zero patch rather than print "26.0.0".
    func testTheOSVersionIsSortableAndDropsAZeroPatch() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expected = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        XCTAssertEqual(AppInfo.osVersion, expected)
        XCTAssertFalse(AppInfo.osVersion.contains("Version"))
        XCTAssertFalse(AppInfo.osVersion.contains("Build"))
        let parts = AppInfo.osVersion.split(separator: ".")
        XCTAssertTrue((2...3).contains(parts.count))
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
        if version.patchVersion == 0 { XCTAssertEqual(parts.count, 2) }
    }

    func testTheReviewLinkTargetsThisAppsStoreRecord() throws {
        let url = try XCTUnwrap(AppInfo.writeReviewURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "apps.apple.com")
        XCTAssertEqual(components.path, "/app/id\(AppInfo.appStoreID)")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "action" })?.value,
                       "write-review")
        XCTAssertTrue(AppInfo.appStoreID.allSatisfy(\.isNumber))
    }
}
