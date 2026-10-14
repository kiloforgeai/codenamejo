import XCTest
@testable import CodenameJo

/// Resolving a spoken name against the mailbox. The tier — not the score — decides whether
/// the assistant treats a row as the person asked for, so the boundaries between an exact
/// name, a sound-alike and a loose guess are the behaviour worth pinning.
final class NameMatchTests: XCTestCase {

    // MARK: - Tokens

    func testHonorificsAndFillerAreDroppedFromASpokenName() {
        XCTAssertEqual(NameMatch.tokens(of: "Dr Kole Smith"), ["kole", "smith"])
        XCTAssertEqual(NameMatch.tokens(of: "email the Kole"), ["kole"])
    }

    /// Dropping everything would leave nothing to search on, so the unfiltered words stand —
    /// and a long title is folded onto the short form the row is likely to carry.
    func testATitleOnlyQueryKeepsItsWordsInTheirShortForm() {
        XCTAssertEqual(NameMatch.tokens(of: "Doctor"), ["dr"])
        // Filler only: every word is filler, so every word stays rather than none.
        XCTAssertEqual(NameMatch.tokens(of: "the email"), ["the", "email"])
        XCTAssertTrue(NameMatch.tokens(of: "   ").isEmpty)
    }

    func testAnAddressSurvivesTokenisationWhole() {
        XCTAssertEqual(NameMatch.tokens(of: "raghav+tag@example.test"), ["raghav+tag@example.test"])
    }

    // MARK: - Addresses

    func testCanonicalAddressDropsPlusTagsDotsAndCase() {
        XCTAssertEqual(
            NameMatch.canonicalAddress(" First.Last+Newsletter@Example.test "),
            "firstlast@example.test")
        XCTAssertEqual(NameMatch.canonicalAddress("first.last@example.test"),
                       NameMatch.canonicalAddress("firstlast@example.test"))
    }

    func testCanonicalAddressLeavesSomethingThatIsNotAnAddressAlone() {
        XCTAssertEqual(NameMatch.canonicalAddress("kole"), "kole")
        XCTAssertEqual(NameMatch.canonicalAddress(""), "")
    }

    // MARK: - Sound

    /// "Shabha" heard for "Sabha" is the case the alternate key exists for: SH and S encode
    /// differently in the primary and identically once X is softened to S.
    func testTheAlternateKeySoftensTheDigraphsSpeechBlurs() {
        XCTAssertEqual(NameMatch.keys("sabha"), ["SP"])
        XCTAssertEqual(NameMatch.keys("shabha"), ["XP", "SP"])
        XCTAssertEqual(NameMatch.keys("cole"), NameMatch.keys("kole"))
        XCTAssertEqual(NameMatch.keys(""), [""])
    }

    func testJaroWinklerStaysInRangeAtItsEdges() {
        XCTAssertEqual(NameMatch.jaroWinkler("kole", "kole"), 1)
        XCTAssertEqual(NameMatch.jaroWinkler("", "kole"), 0)
        XCTAssertEqual(NameMatch.jaroWinkler("kole", ""), 0)
        // The match window can start past the end of the shorter string; an unclamped range traps.
        let lopsided = NameMatch.jaroWinkler("abcdefghij", "a")
        XCTAssertGreaterThanOrEqual(lopsided, 0)
        XCTAssertLessThanOrEqual(lopsided, 1)
        XCTAssertGreaterThan(NameMatch.jaroWinkler("kole", "kolo"), NameMatch.jaroWinkler("kole", "zzzz"))
    }

    // MARK: - Quality

    func testAnAddressQueryIsAnIdentityTestAndNotASearch() {
        let hit = NameMatch.quality(
            name: "Someone Else", email: "raghav@example.test",
            tokens: ["Raghav+tag@Example.test"])
        XCTAssertEqual(hit.tier, .name)
        XCTAssertEqual(hit.score, 2)

        // A name that matches cannot rescue an address that does not.
        let miss = NameMatch.quality(
            name: "Raghav Kumar", email: "raghav@example.test", tokens: ["raghav@other.test"])
        XCTAssertEqual(miss.tier, .loose)
        XCTAssertEqual(miss.score, 0)
    }

    func testAnExactWordIsTheNameTierAndEveryMatchedTokenAddsToTheScore() {
        let one = NameMatch.quality(name: "Kole Smith", email: "kole@example.test", tokens: ["kole"])
        XCTAssertEqual(one.tier, .name)
        XCTAssertEqual(one.score, 2, accuracy: 0.0001)

        let both = NameMatch.quality(
            name: "Kole Smith", email: "kole@example.test", tokens: ["kole", "smith"])
        XCTAssertEqual(both.tier, .name)
        XCTAssertEqual(both.score, 2, accuracy: 0.0001)

        let half = NameMatch.quality(
            name: "Kole Smith", email: "kole@example.test", tokens: ["kole", "jones"])
        XCTAssertEqual(half.tier, .name)
        XCTAssertEqual(half.score, 1.5, accuracy: 0.0001)
    }

    func testTheLocalPartOfTheAddressIsSearchedAlongsideTheDisplayName() {
        let match = NameMatch.quality(
            name: "", email: "kole.smith@example.test", tokens: ["smith"])
        XCTAssertEqual(match.tier, .name)
    }

    func testASoundAlikeIsItsOwnTierAndNotAName() {
        let heard = NameMatch.quality(
            name: "Sabha Rao", email: "sabha@example.test", tokens: ["shabha"])
        XCTAssertEqual(heard.tier, .soundsLike)
        XCTAssertEqual(heard.score, 1.6, accuracy: 0.0001)
    }

    /// A short phonetic key collides with much longer names — "seb" and "sabha" both encode
    /// to SP — so a two-letter key only counts when the words are about the same length.
    func testAShortPhoneticKeyDoesNotMatchAMuchLongerName() {
        let offered = NameMatch.quality(
            name: "Mike Seb", email: "mike.seb@example.test", tokens: ["shabha"])
        XCTAssertEqual(offered.tier, .loose)
        XCTAssertEqual(offered.score, 0)
    }

    func testAPrefixOfAtLeastThreeLettersMatchesAndAShorterOneDoesNot() {
        XCTAssertEqual(
            NameMatch.quality(name: "Shabham Rao", email: "s@example.test", tokens: ["sha"]).tier,
            .name)
        XCTAssertEqual(
            NameMatch.quality(name: "Shabham Rao", email: "rao@example.test", tokens: ["sh"]).tier,
            .loose)
    }

    func testNothingToSearchForMatchesNothing() {
        let empty = NameMatch.quality(name: "Kole Smith", email: "kole@example.test", tokens: [])
        XCTAssertEqual(empty.tier, .loose)
        XCTAssertEqual(empty.score, 0)

        let unrelated = NameMatch.quality(
            name: "Kole Smith", email: "kole@example.test", tokens: ["priyanka"])
        XCTAssertEqual(unrelated.tier, .loose)
        XCTAssertEqual(unrelated.score, 0)
    }
}
