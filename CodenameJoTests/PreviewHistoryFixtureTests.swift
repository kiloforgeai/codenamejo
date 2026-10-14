// coverage-target: CodenameJo/Views/PreviewSupport.swift

import XCTest
@testable import CodenameJo

/// The command log and the queue chip, as the screenshot pipeline sees them.
///
/// History draws its filter chips from the services its rows name, so a seeded turn for
/// a service the app cannot call sits under no chip — and a screenshot of a row for an
/// unwired connector is a promise the build cannot keep. The queue chip has the opposite
/// problem: it only appears while a walk is running, so it is in a screenshot at all only
/// because the preview store pins one, and the pin has to read as *partway through* a
/// walk rather than as a list that was just printed.
///
/// Both stores also override the method that would otherwise go to the network. Those
/// overrides are the difference between a fixture and an empty state: the real `refresh`
/// finds nothing, which is what blanked the chip the moment a preview simulated a turn.
@MainActor
final class PreviewHistoryFixtureTests: XCTestCase {

    // MARK: - The command log

    func testTheSeededCommandLogIsNotEmpty() {
        let store = PreviewCommandStore()

        XCTAssertFalse(store.commands.isEmpty, "An empty log previews as History's empty state")
        XCTAssertEqual(Set(store.commands.map(\.id)).count, store.commands.count)
    }

    /// A refresh from a screen must not replace the fixtures: the real one reads the
    /// backend, finds nothing in a preview, and leaves the screenshot blank.
    func testRefreshingAPreviewLogKeepsTheFixturesRatherThanReadingTheBackend() async {
        let store = PreviewCommandStore()
        let before = store.commands.map(\.id)

        await store.refresh()

        XCTAssertEqual(store.commands.map(\.id), before)
        XCTAssertFalse(store.isLoading)
    }

    /// Chips are the intersection of the names the rows carry with the services the app
    /// can connect. A row naming anything else is unreachable by every filter.
    func testEverySeededTurnNamesAServiceHistoryKnows() {
        let known = Set(CommandRecord.knownServices.map(\.name))

        for command in PreviewCommandStore().commands {
            XCTAssertTrue(known.contains(command.serviceName),
                          "\(command.serviceName) has no chip and no icon to draw")
        }
    }

    /// The icon is looked up from the name at draw time, so a hand-written icon that
    /// disagrees with the lookup renders one symbol in the row and another on the chip.
    func testEverySeededTurnCarriesTheIconItsServiceResolvesTo() {
        for command in PreviewCommandStore().commands {
            XCTAssertEqual(command.serviceIcon, CommandRecord.icon(for: command.serviceName),
                           "\(command.serviceName) draws two different symbols")
        }
    }

    func testNoSeededTurnAdvertisesAnUnwiredConnector() {
        let names = PreviewCommandStore().commands.map { $0.serviceName.lowercased() }

        for unwired in ["github", "notion"] {
            XCTAssertFalse(names.contains(unwired),
                           "\(unwired) is unwired, so the row would sit under no chip")
        }
    }

    /// History is read newest first. The fixtures are hand-ordered, and an out-of-order
    /// one would be a screenshot of a log that sorts wrongly.
    func testTheSeededTurnsAreNewestFirst() {
        let issued = PreviewCommandStore().commands.map(\.issuedAt)

        XCTAssertEqual(issued, issued.sorted(by: >))
    }

    /// The wait figure is optional on purpose: a turn written before it was measured has
    /// to stay distinguishable from one measured at zero, so the row has to look right
    /// both ways — which needs one of each in the fixtures.
    func testTheSeededTurnsCoverBothAMeasuredWaitAndAnUnmeasuredOne() {
        let commands = PreviewCommandStore().commands

        XCTAssertTrue(commands.contains { $0.latency != nil }, "No row shows the wait figure at all")
        XCTAssertTrue(commands.contains { $0.latency == nil },
                      "Every row measured hides the case most stored history actually is")
    }

    /// Each row draws a question and an answer. Either side empty is a half-drawn row,
    /// and both are what the screenshot is of.
    func testEverySeededTurnHasBothAQuestionAndAnAnswer() {
        for command in PreviewCommandStore().commands {
            XCTAssertFalse(command.commandText.isEmpty)
            XCTAssertFalse(command.responseText.isEmpty)
            XCTAssertGreaterThan(command.durationSeconds, 0, "A turn that took no time reads as unmeasured")
        }
    }

    // MARK: - The queue chip

    /// Fourth of twelve: visibly partway, where "1 of 12" reads as a list that has just
    /// been printed and a finished walk draws no chip at all.
    func testTheSeededQueueChipIsVisiblyPartwayThroughAWalk() throws {
        let progress = try XCTUnwrap(PreviewTriageQueueStore().progress)

        XCTAssertGreaterThan(progress.position, 1, "The first position does not read as progress")
        XCTAssertLessThan(progress.position, progress.queued)
        XCTAssertFalse(progress.done, "A finished queue draws no chip")
    }

    /// Position and remaining describe the same pile from both ends; a pair that does not
    /// add up puts a count on screen that contradicts itself.
    func testTheSeededQueueCountsAgreeWithEachOther() throws {
        let progress = try XCTUnwrap(PreviewTriageQueueStore().progress)

        XCTAssertEqual(progress.position + progress.remaining - 1, progress.queued)
        XCTAssertNotNil(progress.account, "The chip names the mailbox being walked")
    }
}
