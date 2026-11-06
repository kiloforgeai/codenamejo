import XCTest
@testable import CodenameJo

final class EmailLinkChoiceTests: XCTestCase {
    func testInvitationChoicesExcludeFootersActionsAndDuplicateTrackingVariants() throws {
        let html = #"<a href="https://events.example.test/morning?utm_source=mail">Morning workshop</a><a href="https://events.example.test/morning?utm_source=copy#top">Morning workshop</a><a href="https://events.example.test/evening">Evening workshop</a><a href="https://events.example.test/confirm?event=morning">Confirm RSVP</a><a href="https://example.test/unsubscribe">Unsubscribe</a><a href="https://linkedin.com/example">LinkedIn</a>"#
        let links = EmailLinkTool.links(html: html, text: "https://events.example.test/morning")
        XCTAssertEqual(links.count, 5)
        guard case .failure(let refusal) = EmailLinkTool.select(links, hint: "event") else { return XCTFail("Must ask which event") }
        let choices = EmailLinkTool.choices(in: refusal.text)
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices[0].label.contains("Morning workshop"))
        XCTAssertTrue(choices[1].label.contains("Evening workshop"))
        guard case .success(let selected) = EmailLinkTool.select(links, hint: "", choice: choices[1].id) else { return XCTFail("Exact choice must resolve") }
        XCTAssertEqual(selected.url.path, "/evening")
        guard case .success(let named) = EmailLinkTool.select(links, hint: "Morning workshop") else { return XCTFail("Unique label must resolve") }
        XCTAssertEqual(named.url.path, "/morning")
        for candidate in links where candidate.blocked != nil || candidate.noise {
            guard case .failure = EmailLinkTool.select(links, hint: "", choice: candidate.id) else { return XCTFail("Unsafe choice opened") }
        }
        guard case .failure = EmailLinkTool.select(links, hint: "", choice: "obsolete-id") else { return XCTFail("Expired choice opened") }
    }

    func testBlockedDuplicateCannotBeReintroducedByItsBareURL() {
        let links = EmailLinkTool.links(html: #"<a href="https://events.example.test/ticket">Confirm attendance</a>"#,
            text: "https://events.example.test/ticket")
        XCTAssertEqual(links.count, 1)
        guard case .failure = EmailLinkTool.select(links, hint: "ticket") else { return XCTFail("State-changing label was lost") }
    }
}
