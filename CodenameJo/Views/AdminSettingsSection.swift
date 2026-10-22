import FactoryKit
import SwiftUI

/// Settings → Admin: the rows that are ours rather than the user's.
///
/// **The staff block is a few pushes and inline rows now.** It was five sections
/// stacked in the one Settings list, which put roughly sixty staff controls between
/// Appearance and Sign Out and made the screen unscrollable for everyone who only
/// wanted the top of it.
///
/// **`Voice session` held the hands-free tuning and barge-in readouts until #86.** The
/// measurements settled the defaults, so the knobs became constants and the readouts
/// went. Only the dial timing is left.
///
/// **`Mail` went too.** Thread grouping, suggested actions and the queue's automatic
/// start are the defaults now. The signature toggle lives in Settings → Sending.
///
/// **Record calls left on 2026-08-18 and Voice notes followed it**, both now Settings →
/// **Voice** on every account (`ProfileView.voiceSection`). They failed the test the two
/// remaining rows pass: they are decisions about the user's own microphone, not levers on
/// our own build. Voice notes was here only because its controls were staff-only, and
/// once the button was everyone's a switch nobody could see was a switch for a button
/// most accounts now get. `ProfileView` draws this section below Sign Out.
///
/// **Debug builds only.** Messages moved to its own Settings section, as a user feature
/// rather than a lever on our build; what is left here is staff-only.
#if DEBUG
@MainActor
protocol AdminSectionHandler {}

struct AdminSection<Interactor: ViewWithModelLifecycleObserver<AdminSectionViewModel> & AdminSectionHandler>: View {
    @StateObject var viewModel: AdminSectionViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        Section {
            ProfileDossierAdminComponent.make()
            dialTimingRow
        } header: {
            SettingsRow.header("Admin")
        } footer: {
            SettingsRow.footer("Debug builds only.")
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

    /// The last dial's timing, one push away.
    private var dialTimingRow: some View {
        NavigationLink {
            AdminDetailList(title: "Dial timing") {
                DialTimingSection()
            }
        } label: {
            SettingsRow.label(
                "Dial timing",
                icon: "stopwatch",
                detail: "How long the last dial took, leg by leg."
            )
        }
        .accessibilityIdentifier("adminDialTimingRow")
        .listRowBackground(Theme.surface)
    }
}

// MARK: - Pushed screens

/// The list chrome the two Admin pushes share with `ProfileView`, so a pushed screen
/// can't drift from the one it was lifted out of.
private struct AdminDetailList<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List { content }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Component

@MainActor
struct AdminSectionComponent {
    @ViewBuilder
    static func make() -> some View {
        AdminSection(viewModel: AdminSectionViewModel(), interactor: AdminSectionInteractor())
    }
}

// MARK: - View model

@MainActor
final class AdminSectionViewModel: ViewModel {}

// MARK: - Interactor

@MainActor
final class AdminSectionInteractor: ViewModelInteractor<AdminSectionViewModel> {}

extension AdminSectionInteractor: AdminSectionHandler {}
#endif
