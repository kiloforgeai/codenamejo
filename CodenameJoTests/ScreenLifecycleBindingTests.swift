import Combine
import SwiftUI
import XCTest

@testable import CodenameJo

// coverage-target: CodenameJo/ThirdPartyCode/IMVVM/View+Lifecycle.swift
// coverage-target: CodenameJo/ThirdPartyCode/IMVVM/TypeErasedView.swift
// coverage-target: CodenameJo/ThirdPartyCode/IMVVM/AnyCancellable+Interactor.swift
// coverage-target: CodenameJo/ThirdPartyCode/IMVVM/Task+Interactor.swift

/// Binding an observer to a view, the type eraser the binding can hand back, and the two
/// cancel bags every interactor in the app subscribes through.
///
/// The rule the whole architecture rests on is that lifecycle work runs on *appear*, not on
/// construction — `bind` only installs the hooks. A `bind` that delivered `viewDidAppear`
/// as it was called would run every screen's `onLoad` while the parent was merely building
/// its body.
///
/// `cancelOnViewDidDisappear` and `cancelOnDeinit` are the only ways that work is torn down,
/// and the difference between them is the point: one ends when the screen leaves, the other
/// lives as long as the interactor does. Getting them the wrong way round is a subscription
/// that keeps firing into a screen nobody is looking at, or one that dies the first time the
/// user navigates away and never comes back.
@MainActor
final class ScreenLifecycleBindingTests: XCTestCase {

    /// A plain interactor. Nothing is overridden: the bags under test belong to the base
    /// class, and every screen's interactor inherits exactly this behaviour.
    private final class Probe: Interactor {}

    private func loaded() -> Probe {
        let probe = Probe()
        probe.viewDidAppear()
        return probe
    }

    // MARK: - Binding

    func testBindingAnObserverDoesNotDeliverAppearance() {
        let probe = Probe()

        _ = Text("hello").bind(observer: probe)

        XCTAssertFalse(probe.hasViewAppeared,
                       "Building the view is not the view appearing.")
        XCTAssertFalse(probe.isLoaded, "`onLoad` must wait for the first appearance.")
    }

    func testBindingDoesNotDeliverDisappearanceEither() {
        let probe = Probe()
        probe.viewDidAppear()

        _ = Text("hello").bind(observer: probe)

        XCTAssertTrue(probe.hasViewAppeared,
                      "Re-binding an on-screen observer must not tear its subscriptions down.")
    }

    func testTypeErasingAConcreteViewYieldsAnAnyViewBody() {
        let erased = Text("hello").typeErased()

        XCTAssertTrue(type(of: erased.body) == AnyView.self,
                      "The eraser's whole job is to present one stable body type.")
    }

    func testTypeErasedViewBuiltFromAnAnyViewKeepsAnAnyViewBody() {
        let erased = TypeErasedView(AnyView(Text("hello")))

        XCTAssertTrue(type(of: erased.body) == AnyView.self)
    }

    func testRewrappingAnAlreadyErasedViewStaysOneEraserDeep() {
        let once = Text("hello").typeErased()

        let twice = TypeErasedView(once)

        XCTAssertTrue(type(of: twice) == TypeErasedView.self)
        XCTAssertTrue(type(of: twice.body) == AnyView.self,
                      "Re-erasing takes the existing `AnyView` rather than wrapping another around it.")
    }

    // MARK: - AnyCancellable

    func testViewScopedSubscriptionIsCancelledWhenTheViewDisappears() {
        let probe = loaded()
        var cancelled = false
        AnyCancellable { cancelled = true }.cancelOnViewDidDisappear(of: probe)

        XCTAssertFalse(cancelled)
        probe.viewDidDisappear()

        XCTAssertTrue(cancelled, "A view-scoped subscription must not outlive the screen.")
    }

    func testViewScopedSubscriptionSurvivesWhileTheScreenIsUp() {
        let probe = loaded()
        var cancelled = false
        AnyCancellable { cancelled = true }.cancelOnViewDidDisappear(of: probe)

        XCTAssertFalse(cancelled, "Binding is not cancelling; the bag retains it until the view goes.")
    }

    func testViewScopedSubscriptionIsCancelledOnceAndOnlyOnce() {
        let probe = loaded()
        var cancellations = 0
        AnyCancellable { cancellations += 1 }.cancelOnViewDidDisappear(of: probe)

        probe.viewDidDisappear()
        probe.viewDidDisappear()

        XCTAssertEqual(cancellations, 1,
                       "A second disappear with no appear between them is not a lifecycle event.")
    }

    func testDeinitScopedSubscriptionOutlivesTheViewDisappearing() {
        let probe = loaded()
        var cancelled = false
        AnyCancellable { cancelled = true }.cancelOnDeinit(of: probe)

        probe.viewDidDisappear()

        XCTAssertFalse(cancelled,
                       "Work bound to the interactor's life has to survive the screen leaving.")
    }

    func testDeinitScopedSubscriptionIsCancelledWhenTheInteractorGoes() {
        var cancelled = false
        do {
            let probe = loaded()
            AnyCancellable { cancelled = true }.cancelOnDeinit(of: probe)
            XCTAssertFalse(cancelled)
        }

        XCTAssertTrue(cancelled, "Releasing the interactor is what ends a deinit-scoped subscription.")
    }

    func testReappearingRearmsTheViewScopedBag() {
        let probe = loaded()
        AnyCancellable {}.cancelOnViewDidDisappear(of: probe)
        probe.viewDidDisappear()
        probe.viewDidAppear()

        var cancelled = false
        AnyCancellable { cancelled = true }.cancelOnViewDidDisappear(of: probe)
        probe.viewDidDisappear()

        XCTAssertTrue(cancelled,
                      "A screen shown a second time must be able to subscribe a second time.")
    }

    // MARK: - Task

    func testAnyCancellableCancelsTheTaskItWraps() async {
        let task = Task { try? await Task.sleep(for: .seconds(60)) }
        let cancellable = task.anyCancellable

        XCTAssertFalse(task.isCancelled)
        cancellable.cancel()

        XCTAssertTrue(task.isCancelled)
        _ = await task.value
    }

    func testATaskIsCancellableThroughTheCombineProtocol() async {
        let task = Task { try? await Task.sleep(for: .seconds(60)) }
        let erased: any Cancellable = task

        erased.cancel()

        XCTAssertTrue(task.isCancelled,
                      "`Task` conforms to `Cancellable` so it can go in the same bag as a subscription.")
        _ = await task.value
    }

    func testViewScopedTaskIsCancelledWhenTheViewDisappears() async {
        let probe = loaded()
        let task = Task { try? await Task.sleep(for: .seconds(60)) }
        task.cancelOnViewDidDisappear(of: probe)

        XCTAssertFalse(task.isCancelled)
        probe.viewDidDisappear()

        XCTAssertTrue(task.isCancelled)
        _ = await task.value
    }

    func testDeinitScopedTaskOutlivesTheViewDisappearing() async {
        let probe = loaded()
        let task = Task { try? await Task.sleep(for: .seconds(60)) }
        task.cancelOnDeinit(of: probe)

        probe.viewDidDisappear()

        XCTAssertFalse(task.isCancelled,
                       "A load started for the interactor is not abandoned because the screen scrolled away.")
        task.cancel()
        _ = await task.value
    }

    func testDeinitScopedTaskIsCancelledWhenTheInteractorGoes() async {
        let task = Task { try? await Task.sleep(for: .seconds(60)) }
        do {
            let probe = loaded()
            task.cancelOnDeinit(of: probe)
            XCTAssertFalse(task.isCancelled)
        }

        XCTAssertTrue(task.isCancelled)
        _ = await task.value
    }

    func testCancellingAnAlreadyFinishedTaskIsHarmless() async {
        let task = Task<Int, Never> { 7 }
        let value = await task.value
        let probe = loaded()

        task.cancelOnViewDidDisappear(of: probe)
        probe.viewDidDisappear()

        XCTAssertEqual(value, 7, "A finished task keeps its result; cancellation after the fact is a no-op.")
    }
}
