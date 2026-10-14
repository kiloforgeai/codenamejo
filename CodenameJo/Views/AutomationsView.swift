import Combine
import FactoryKit
import SwiftUI

/// What the Rules page can do.
protocol AutomationsViewHandler {
    func setRule(_ rule: StandingRule, enabled: Bool, viewModel: AutomationsViewModel)
}

/// The user's standing rules. Off the pager for now (commented out in `ContentView`).
/// Screens name themselves in the content area rather than with a nav title.
struct AutomationsView<
    Interactor: ViewWithModelLifecycleObserver<AutomationsViewModel> & AutomationsViewHandler
>: View {
    @StateObject var viewModel: AutomationsViewModel
    @StateObject var interactor: Interactor
    /// How "back to the voice screen" is performed — see `ProfileView`'s note. This is a
    /// pager pane, so `dismiss` does nothing and the pager supplies this instead.
    var onClose: (() -> Void)?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Rules")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    rulesTab
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Trailing: this pane sits left of the voice screen, so back points right.
                ToolbarItem(placement: .topBarTrailing) {
                    if onClose != nil {
                        Button {
                            onClose?()
                        } label: {
                            Label("Close", systemImage: "chevron.right")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("automationsBackButton")
                    }
                }
            }
        }
        .bind(observer: interactor, viewModel: viewModel)
    }

    // MARK: - Rules

    /// The user's standing rules — the thing the assistant does every time, without being
    /// asked again.
    @ViewBuilder
    private var rulesTab: some View {
        List {
            Section {
                ForEach(StandingRule.allCases) { rule in
                    ruleRow(rule)
                }
            } footer: {
                // Tells the user these switches are also sayable, which a switch can't show.
                Text("You can switch these by voice too: \"archive an email after I reply "
                     + "to it\". Nothing already filed comes back when one goes off.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// One rule: what it does, and a switch. No delete: the three rules are fixed, so off is gone.
    private func ruleRow(_ rule: StandingRule) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(rule.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { viewModel.rules.contains(rule) },
                // Straight to the interactor: the assistant can switch one mid-call, so
                // the view must not hold its own answer.
                set: { interactor.setRule(rule, enabled: $0, viewModel: viewModel) },
            ))
            .labelsHidden()
            .tint(Theme.toggleOn)
            .accessibilityLabel("\(rule.title), \(viewModel.rules.contains(rule) ? "on" : "off")")
            .accessibilityIdentifier("ruleToggle-\(rule.rawValue)")
        }
        .listRowBackground(Theme.surface)
    }
}

@MainActor
struct AutomationsViewComponent {
    @ViewBuilder
    static func make(onClose: (() -> Void)? = nil) -> some View {
        AutomationsView(
            viewModel: AutomationsViewModel(),
            interactor: AutomationsViewInteractor(),
            onClose: onClose)
    }
}

@MainActor
final class AutomationsViewModel: ViewModel {
    /// Which of the three filing rules are on. A set rather than a per-rule flag so the
    /// rows read it the same way whether it was switched here or by voice.
    @Published var rules: Set<StandingRule> = []
}

@MainActor
final class AutomationsViewInteractor: ViewModelInteractor<AutomationsViewModel> {
    @CancellableBuilder
    override func onLoad(viewModel: AutomationsViewModel) -> [AnyCancellable] {
        super.onLoad(viewModel: viewModel)

        // The switches live in `UserDefaults` like every other setting, and the profile load
        // writes them from under this screen, so watch the defaults themselves.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in viewModel.rules = Self.switchedOn() }
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: AutomationsViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        // The subscription above only carries changes; on a cold launch the defaults have
        // never been read.
        viewModel.rules = Self.switchedOn()
    }
}

extension AutomationsViewInteractor: AutomationsViewHandler {
    /// Written to `UserDefaults`, which `UserProfileStore` syncs. The row redraws off
    /// `didChangeNotification`, so a switch moved by voice lands the same way.
    func setRule(_ rule: StandingRule, enabled: Bool, viewModel: AutomationsViewModel) {
        UserDefaults.standard.set(enabled, forKey: rule.storageKey)
        viewModel.rules = Self.switchedOn()
    }

    static func switchedOn() -> Set<StandingRule> {
        Set(StandingRule.allCases.filter(\.isOn))
    }
}

#if DEBUG
import Prefire

#Preview("AutomationsView") {
    PreviewAutomationsViewHost()
        .snapshot(delay: 0.5)
}
#endif
