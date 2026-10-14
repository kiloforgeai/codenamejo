import FactoryKit
import SwiftUI

/// Post-onboarding root: a three-pane horizontal pager with History left of the voice screen and
/// Settings right. Container view — NO #Preview.
struct ContentView: View {
    /// The pager's pages, left to right.
    enum Pane: Hashable {
        // Rules is off the pager, not deleted.
        // case automations
        case history, command, settings
    }

    @State private var pane: Pane? = .command

    /// True from a button press until its page animation has had time to finish. The
    /// side panes read it — see `SidePane` — and the timer below clears it.
    @State private var settling = false
    @State private var settleTask: Task<Void, Never>?
    @State private var builtPanes = BuiltPanes()

    // Pane view models live in the panes, not here: re-rendering the pager mid-animation cancels
    // `show(_:)`'s slide, so nothing this view observes may publish on every pane change.

    /// Requests to open History from a pane that cannot scroll the pager. See `HistoryRouter`.
    @ObservedObject private var historyRouter = Container.shared.historyRouter()

    /// External capture requests (controls, Action Button, Siri, widget). Observed here too so the
    /// pager brings the voice screen back; `CommandView` starts the work.
    @ObservedObject private var launcher = Container.shared.voiceLauncher()

    /// Not `@ObservedObject`: while a note records, `elapsed` republishes twice a second, which
    /// must not re-render the pager.
    private let memoRecorder = Container.shared.memoRecorder()

    /// Notes waiting to be read back, for the count on the History button.
    @ObservedObject private var memoQueue = Container.shared.memoQueue()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // One `NavigationStack` per pane, never one around the pager: a page `TabView` keeps
            // neighbours alive, and a shared bar collects every pane's toolbar items.
            TabView(selection: $pane) {
                // NavigationStack { AutomationsViewComponent.make(onClose: { show(.command) }) }
                //     .tag(Pane.automations as Pane?)

                NavigationStack {
                    SidePane(pane: .history, settling: settling, built: builtPanes) {
                        HistoryPane(onClose: { show(.command) })
                    }
                }
                .tag(Pane.history as Pane?)

                NavigationStack { commandPane }
                    .tag(Pane.command as Pane?)

                NavigationStack {
                    SidePane(pane: .settings, settling: settling, built: builtPanes) {
                        SettingsPane(onClose: { show(.command) })
                    }
                }
                .tag(Pane.settings as Pane?)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The pager takes the whole screen and hands the safe area to the stacks; otherwise
            // each pane's bar sits 10 pt low.
            .ignoresSafeArea()
            // Only the pane half is consumed here; the tab half belongs to History's own
            // interactor.
            .onChange(of: historyRouter.pendingPane) { _, wanted in
                guard wanted else { return }
                show(.history)
                historyRouter.consumePane()
            }
            // External presses bring the pager home to the voice pane. Rising edge only, and
            // nothing is consumed here: these are `CommandView`'s requests.
            .onChange(of: launcher.pendingLaunch) { _, wanted in
                guard wanted else { return }
                show(.command)
            }
            .onChange(of: launcher.pendingMemo) { _, wanted in
                // A second press is the stop, which `memoTapped` routes to History itself; the stop
                // runs on `AudioQueue` after this returns, so it still reads as recording here.
                guard wanted, !memoRecorder.isRecording else { return }
                show(.command)
            }
        }
    }

    /// The voice pane's navigation bar. `CommandView` adds Mute and End to the same bar's bottom
    /// placement; toolbar items accumulate down the hierarchy.
    private var commandPane: some View {
        VoicePane()
            // House rule: no non-empty nav titles, `.inline` only.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ToolbarItem(placement: .topBarLeading) {
                //     Button {
                //         show(.automations)
                //     } label: {
                //         Label("Automations", systemImage: "wand.and.sparkles")
                //             .labelStyle(.iconOnly)
                //     }
                //     .accessibilityLabel("Automations")
                //     .accessibilityIdentifier("automationsButton")
                // }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        show(.history)
                    } label: {
                        // `.iconOnly` rather than a bare `Image`: an image-only label loses the 44
                        // pt tap target in an iOS 26 toolbar.
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .labelStyle(.iconOnly)
                    }
                    // This is the only route to waiting notes, so the button says they are waiting.
                    .badge(memoQueue.readyCount)
                    .accessibilityLabel(
                        memoQueue.readyCount > 0
                            ? "History — \(memoQueue.readyCount) notes waiting to send"
                            : "History")
                    .accessibilityIdentifier("historyButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        show(.settings)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
                }
            }
    }

    /// Button navigation is logged here; swipes update the selection directly. `settling` outlasts
    /// the animation so building an unbuilt side pane doesn't cut the slide to a jump.
    private func show(_ target: Pane) {
        settleTask?.cancel()
        settling = true
        withAnimation(.snappy) { pane = target }
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            settling = false
        }
    }
}

// MARK: - Panes

/// Which side panes have drawn their real content at least once. A reference, written
/// during body evaluation, so latching a pane as built never re-renders anything.
private final class BuiltPanes {
    var panes: Set<ContentView.Pane> = []
}

/// A side pane that stays a blank backdrop during a button-driven page change unless it has drawn
/// before. Swipes never raise `settling`.
private struct SidePane<Content: View>: View {
    let pane: ContentView.Pane
    let settling: Bool
    let built: BuiltPanes
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !settling || built.panes.contains(pane) {
                let _ = built.panes.insert(pane)
                content()
            }
        }
    }
}

// Each pane owns its view model and interactor so their publishing re-renders the pane and
// nothing above it.

private struct HistoryPane: View {
    @StateObject private var viewModel = HistoryViewModel()
    @StateObject private var interactor = HistoryViewInteractor()
    let onClose: () -> Void

    var body: some View {
        HistoryViewComponent.make(viewModel: viewModel, interactor: interactor, onClose: onClose)
    }
}

private struct VoicePane: View {
    @StateObject private var viewModel = CommandViewComponent.makeViewModel()
    @StateObject private var interactor = CommandViewInteractor()

    var body: some View {
        CommandViewComponent.make(viewModel: viewModel, interactor: interactor)
    }
}

private struct SettingsPane: View {
    @StateObject private var viewModel = ProfileViewModel()
    @StateObject private var interactor = ProfileViewInteractor()
    let onClose: () -> Void

    var body: some View {
        ProfileViewComponent.make(viewModel: viewModel, interactor: interactor, onClose: onClose)
    }
}
