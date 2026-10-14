import Foundation
import XCTest
@testable import CodenameJo

/// The phone's half of the token-server sign-in: the PKCE pair, the start URL, and who the
/// `id_token` says consented.
@MainActor
final class GoogleSignInFlowTests: XCTestCase {
    func testTheChallengeIsTheRFC7636S256OfTheVerifier() {
        let pkce = GoogleSignInFlow.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAFreshVerifierAndStateFitTheServersRules() {
        let pkce = GoogleSignInFlow.PKCE()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertNotNil(pkce.verifier.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression))
        XCTAssertNotNil(pkce.challenge.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression))
        XCTAssertNotEqual(GoogleSignInFlow.randomToken(), GoogleSignInFlow.randomToken())
    }

    func testTheStartURLCarriesTheChallengeStateAndHint() throws {
        let pkce = GoogleSignInFlow.PKCE()
        let url = try XCTUnwrap(GoogleSignInFlow.startURL(
            base: URL(string: "https://tokens.example.test")!, pkce: pkce, state: "state-1234567890ab",
            hint: "me+jo@example.test"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "tokens.example.test")
        XCTAssertEqual(components.path, "/api/google/start")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["challenge": pkce.challenge, "state": "state-1234567890ab",
                               "login_hint": "me+jo@example.test"])
        XCTAssertFalse(url.absoluteString.contains(pkce.verifier), "The verifier never leaves before the exchange")
    }

    func testTheIdTokenGivesTheAddressSubAndName() throws {
        let payload = "eyJzdWIiOiAiMTIzNCIsICJlbWFpbCI6ICJBbGV4QEV4YW1wbGUuY29tIiwgIm5hbWUiOiAiQWxleCBSaXZlcmEifQ"
        let identity = try XCTUnwrap(GoogleSignInFlow.Identity(idToken: "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"))
        XCTAssertEqual(identity, GoogleSignInFlow.Identity(idToken: "x.\(payload).y"))
        XCTAssertEqual(identity.email, "alex@example.com")
        XCTAssertEqual(identity.sub, "1234")
        XCTAssertEqual(identity.name, "Alex Rivera")
        XCTAssertNil(GoogleSignInFlow.Identity(idToken: "not-a-jwt"))
    }

    func testTheGreetingUsesAFirstNameOrNothing() {
        let first = LiveSessionSetup.greetingFirstName
        XCTAssertEqual(first(["Alex Rivera"]), "Alex")
        XCTAssertEqual(first(["Rivera, Alex"]), "Alex")
        XCTAssertEqual(first(["\"José\" María"]), "José")
        XCTAssertEqual(first([nil, "me@example.test", "+1 (415) 555-0100", "Kate"]), "Kate")
        XCTAssertNil(first(["me@example.test", "J", nil]))
    }

    func testSummariesKnowTheOwnersNames() {
        let grants = [
            GoogleAccountStore.Grant(email: "work@example.test", refreshToken: "r", scopes: [], grantedAt: Date(),
                                     isPrimary: false, displayName: "Alex R"),
            GoogleAccountStore.Grant(email: "me@example.test", refreshToken: "r", scopes: [], grantedAt: Date(),
                                     isPrimary: true, displayName: "Alex Rivera"),
            GoogleAccountStore.Grant(email: "other@example.test", refreshToken: "r", scopes: [], grantedAt: Date(),
                                     isPrimary: false, displayName: "Someone Else"),
        ]
        XCTAssertEqual(LocalEmailPresentation.ownerNames(for: ["WORK@example.test"], grants: grants),
                       ["Alex R", "Alex Rivera"])
    }
}
