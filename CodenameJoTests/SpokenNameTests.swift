import XCTest
@testable import CodenameJo

final class SpokenNameTests: XCTestCase {
    func testOnlyAPersonsLastFirstIsFlipped() {
        XCTAssertEqual(LocalTriageQueue.speakableName("Lee, Sam"), "Sam Lee")
        XCTAssertEqual(LocalTriageQueue.speakableName("Van Buren, Mary Ann"), "Mary Ann Van Buren")
        XCTAssertEqual(LocalTriageQueue.speakableName("O'Neil, Pat"), "Pat O'Neil")
        for kept in ["de la Cruz, Ana", "Acme, Inc.", "Smith, Jr.", "Sales, Support & Billing", "Lee, Sam, Kim", "Sam Lee"] {
            XCTAssertEqual(LocalTriageQueue.speakableName(kept), kept)
        }
    }
}
