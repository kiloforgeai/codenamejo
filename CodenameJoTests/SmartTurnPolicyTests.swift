import XCTest
@testable import CodenameJo

final class SmartTurnPolicyTests: XCTestCase {
    private let chunk = 0.256

    func testSilenceBeforeAnySpeechNeverEndsATurn() {
        var policy = SmartTurnPolicy()
        for _ in 0..<10 { policy.observe(probability: 0, duration: chunk) }
        XCTAssertFalse(policy.shouldClassify)
        XCTAssertFalse(policy.ready)
    }

    func testAConfidentFinishedScoreEndsTheTurnAtTheFirstCheck() {
        var policy = SmartTurnPolicy()
        policy.observe(probability: 0.9, duration: chunk)
        policy.observe(probability: 0.1, duration: chunk)
        XCTAssertTrue(policy.shouldClassify)
        XCTAssertEqual(policy.threshold, 0.85, accuracy: 0.01)
        policy.classify(completion: 0.9)
        XCTAssertTrue(policy.ready)
    }

    func testAnUnfinishedScoreWaitsAndTheThresholdFalls() {
        var policy = SmartTurnPolicy()
        policy.observe(probability: 0.9, duration: chunk)
        policy.observe(probability: 0.1, duration: chunk)
        policy.classify(completion: 0.6)
        XCTAssertFalse(policy.ready)
        policy.observe(probability: 0.1, duration: chunk)
        policy.observe(probability: 0.1, duration: chunk)
        XCTAssertTrue(policy.shouldClassify)
        XCTAssertEqual(policy.threshold, 0.5, accuracy: 0.01)
        policy.classify(completion: 0.6)
        XCTAssertTrue(policy.ready)
    }

    func testSpeechResumingClearsTheSilence() {
        var policy = SmartTurnPolicy()
        policy.observe(probability: 0.9, duration: chunk)
        policy.observe(probability: 0.1, duration: chunk)
        policy.classify(completion: 0.2)
        policy.observe(probability: 0.8, duration: chunk)
        XCTAssertEqual(policy.silence, 0)
        XCTAssertFalse(policy.shouldClassify)
    }

    func testLongSilenceEndsTheTurnRegardless() {
        var policy = SmartTurnPolicy()
        policy.observe(probability: 0.9, duration: chunk)
        for _ in 0..<6 { policy.observe(probability: 0.1, duration: chunk) }
        XCTAssertTrue(policy.ready)
    }

    func testParadeeMisakiContractsDiphthongsAndPunctuationSpacing() {
        XCTAssertEqual(ParadeeTTS.misaki("hˈeɪ , aɪ ɡˈoʊ ."), "hˈA, I ɡˈO.")
    }
}
