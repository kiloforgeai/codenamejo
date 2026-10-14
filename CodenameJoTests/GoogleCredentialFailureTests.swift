import XCTest
@testable import CodenameJo

/// The typed failure is what decides whether a background mail pass reschedules at all.
/// Classifying a revoked grant as transient retries a doomed round trip on every wake
/// forever; classifying a flat network as revoked marks a working account for reconnecting.
/// The label is also what gets logged, so it has to carry no token material.
@MainActor
final class GoogleCredentialFailureTests: XCTestCase {

    // MARK: - The token server's answers

    private func failure(_ status: Int, _ json: String) -> GoogleTokenServer.Failure? {
        if case .failure(let failure) = GoogleTokenServer.classify(status: status, body: Data(json.utf8)) {
            return failure
        }
        return nil
    }

    func testOnlyGooglesRefusalOfTheGrantIsRevoked() {
        XCTAssertEqual(failure(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#), .revoked)
        // A grant another client issued — an install from before the token server.
        XCTAssertEqual(failure(401, #"{"error":"unauthorized_client"}"#), .revoked)
    }

    func testEverythingElseIsWorthAnotherTry() {
        XCTAssertEqual(failure(503, #"{"error":"disabled"}"#), .failed("disabled"))
        XCTAssertEqual(failure(429, #"{"error":"rate_limited"}"#), .failed("rate_limited"))
        XCTAssertEqual(failure(502, "<html>"), .failed("http_502"))
        XCTAssertEqual(failure(200, #"{"no":"token"}"#), .failed("http_200"))
    }

    func testASuccessCarriesTheGrantedScopes() throws {
        let body = #"{"access_token":"a","expires_in":3599,"scope":"openid https://www.googleapis.com/auth/gmail.modify","refresh_token":"r"}"#
        guard case .success(let tokens) = GoogleTokenServer.classify(status: 200, body: Data(body.utf8)) else {
            return XCTFail("expected tokens")
        }
        XCTAssertEqual(tokens.access_token, "a")
        XCTAssertEqual(tokens.refresh_token, "r")
        XCTAssertEqual(tokens.scopes, ["openid", "https://www.googleapis.com/auth/gmail.modify"])
    }

    // MARK: - Rescheduling

    func testOnlyTransientIsWorthWakingUpFor() {
        XCTAssertTrue(GoogleCredential.Failure.transient("timed out").isWorthRetrying)
        XCTAssertFalse(GoogleCredential.Failure.noStoredGrant.isWorthRetrying)
        // Nobody can re-consent in the background, so these two must stop the schedule.
        XCTAssertFalse(GoogleCredential.Failure.grantRevoked.isWorthRetrying)
        XCTAssertFalse(GoogleCredential.Failure.scopesMissing(granted: []).isWorthRetrying)
    }

    // MARK: - What the label is allowed to say

    func testEachFailureHasItsOwnStableLabel() {
        XCTAssertEqual(GoogleCredential.Failure.noStoredGrant.logLabel, "no_stored_grant")
        XCTAssertEqual(GoogleCredential.Failure.grantRevoked.logLabel, "grant_revoked")
        XCTAssertEqual(GoogleCredential.Failure.scopesMissing(granted: []).logLabel,
                       "scopes_missing")
        XCTAssertEqual(GoogleCredential.Failure.transient("http_429").logLabel,
                       "transient(http_429)")
    }

    func testTheScopesMissingLabelNamesNoScopeItWasGiven() {
        // The label is persisted and sent off the device; the granted list is account data.
        let granted = ["https://www.googleapis.com/auth/gmail.modify",
                       "https://www.googleapis.com/auth/calendar.events"]
        let label = GoogleCredential.Failure.scopesMissing(granted: granted).logLabel
        XCTAssertEqual(label, "scopes_missing")
        for scope in granted {
            XCTAssertFalse(label.contains(scope))
        }
        XCTAssertFalse(label.contains("googleapis"))
    }

    // MARK: - The scope lists the failures are measured against

    func testMailAndCalendarScopeRequirementsAreHeldApart() {
        // Someone who unticked calendar at consent still gets their mail, and the reverse.
        XCTAssertEqual(GoogleCredential.requiredScopes,
                       ["https://www.googleapis.com/auth/gmail.modify"])
        XCTAssertEqual(GoogleCredential.calendarScopes,
                       ["https://www.googleapis.com/auth/calendar.readonly"])
        XCTAssertTrue(
            Set(GoogleCredential.requiredScopes)
                .isDisjoint(with: GoogleCredential.calendarScopes))
    }
}
