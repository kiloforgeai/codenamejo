import Combine
import AVFoundation
import FactoryKit
import XCTest
@testable import CodenameJo

@MainActor
final class DesktopOnboardingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        Container.shared.manager.push()
        let realtime = RealtimeService()
        let audioQueue = AudioQueue()
        Container.shared.realtimeService.register { realtime }
        Container.shared.onboardingAudioQueue.register { audioQueue }
    }

    override func tearDown() async throws {
        Scope.singleton.reset()
        Container.shared.manager.pop()
        try await super.tearDown()
    }

    func testMacWithoutMicrophoneSpeaksAndCanContinueWithoutStartingCapture() async {
        let model = OnboardingSayItViewModel()
        var advances = 0
        let interactor = OnboardingSayItViewInteractor(hasMicrophone: { false }) { advances += 1 }
        let shown = expectation(description: "Missing microphone is surfaced")
        let subscription = model.$inputUnavailable.dropFirst().filter { $0 }.sink { _ in shown.fulfill() }
        interactor.viewDidAppear(viewModel: model)
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertTrue(model.showSkip)
        XCTAssertTrue(model.joSpeaking)
        interactor.skip(viewModel: model)
        interactor.skip(viewModel: model)
        XCTAssertEqual(advances, 1)
        interactor.viewDidDisappear(viewModel: model)
        subscription.cancel()
    }

    func testNotificationStepWithoutMicrophonePlaysAudioAndStillAdvancesOnce() async {
        let model = OnboardingNotificationsViewModel()
        var advances = 0
        let interactor = OnboardingNotificationsViewInteractor(hasMicrophone: { false }) { advances += 1 }
        let checked = expectation(description: "Notification clip plays without an input device")
        let subscription = model.$joSpeaking.dropFirst().filter { $0 }.prefix(1).sink { _ in checked.fulfill() }
        interactor.viewDidAppear(viewModel: model)
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertTrue(model.inputUnavailable)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        interactor.skip(viewModel: model)
        interactor.skip(viewModel: model)
        XCTAssertEqual(advances, 1)
        interactor.viewDidDisappear(viewModel: model)
        subscription.cancel()
    }

    func testSystemVoiceCompletesWithPlaybackOnlySession() async throws {
        let speech = LocalSpeech()
        let finished = expectation(description: "System voice finishes speaking")
        let speaking = Task {
            try await speech.speakWithoutMicrophone("Jo voice test.", choice: .system)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 12)
        speech.stop()
        try await speaking.value
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }

    func testStoppingAndRestartingSpeakerSampleCompletes() async {
        let speech = LocalSpeech()
        speech.preview(.system)
        speech.stop()
        XCTAssertFalse(speech.isPreviewing)
        XCTAssertNil(speech.previewMessage)
        let finished = expectation(description: "New sample completes after cancellation")
        let subscription = speech.$isPreviewing.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        speech.preview(.system)
        await fulfillment(of: [finished], timeout: 12)
        XCTAssertNotNil(speech.previewMessage)
        XCTAssertFalse(speech.isPreviewing)
        speech.stop()
        subscription.cancel()
    }

    func testPreparingWithoutMicrophoneFinishesWithoutWaitingForVoice() async {
        let model = OnboardingPreparingViewModel()
        let finished = expectation(description: "Workspace opens")
        let interactor = OnboardingPreparingViewInteractor(hasMicrophone: { false }) { finished.fulfill() }
        interactor.viewDidAppear(viewModel: model)
        await fulfillment(of: [finished], timeout: 4)
        XCTAssertFalse(model.voiceAvailable)
        XCTAssertFalse(model.waitingForJo)
        interactor.advance(viewModel: model)
        interactor.viewDidDisappear(viewModel: model)
    }

    func testStartSessionWithoutMicrophoneShowsActionableError() async {
        let model = DesktopWorkspaceModel()
        let interactor = DesktopWorkspaceInteractor(hasMicrophone: { false })
        let subscriptions = interactor.onLoad(viewModel: model)
        let shown = expectation(description: "Missing input alert")
        let subscription = model.$showMicUnavailable.dropFirst().filter { $0 }.sink { _ in shown.fulfill() }
        interactor.toggleSession()
        interactor.toggleSession()
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertFalse(model.inSession)
        subscription.cancel()
        subscriptions.forEach { $0.cancel() }
    }

    func testQuickActionWithoutMicrophoneShowsActionableError() async {
        let model = DesktopWorkspaceModel()
        let interactor = DesktopWorkspaceInteractor(hasMicrophone: { false })
        let subscriptions = interactor.onLoad(viewModel: model)
        let shown = expectation(description: "Missing input alert for quick action")
        let subscription = model.$showMicUnavailable.dropFirst().filter { $0 }.sink { _ in shown.fulfill() }
        interactor.quickAction()
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertFalse(model.inSession)
        subscription.cancel()
        subscriptions.forEach { $0.cancel() }
    }
}
