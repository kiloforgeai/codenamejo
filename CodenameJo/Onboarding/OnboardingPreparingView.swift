import Combine
import FactoryKit
import SwiftUI

/// The last onboarding screen: an inbox progress bar the length of the dial it places.
protocol OnboardingPreparingViewHandler {
    func advance(viewModel: OnboardingPreparingViewModel)
}

struct OnboardingPreparingView<Interactor: ViewWithModelLifecycleObserver<OnboardingPreparingViewModel> & OnboardingPreparingViewHandler>: View {
    @StateObject var viewModel: OnboardingPreparingViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        OnboardingScaffold(
            title: "Setting up your inbox",
            subtitle: "Jo is reading what landed while you were signing up."
        ) {
            VStack(spacing: 22) {
                Spacer(minLength: 12)

                PreparingProgressBar(fraction: viewModel.fraction)
                    .padding(.horizontal, 8)

                card

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .animation(.easeInOut(duration: 0.25), value: viewModel.waitingForJo)
            .animation(.easeInOut(duration: 0.25), value: viewModel.index)
        } footer: {
            Text("Jo will start talking in a moment.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
        .navigationBarBackButtonHidden(true)
        .bind(observer: interactor, viewModel: viewModel)
    }

    /// The same glass card as the receipt, one screen back.
    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Your inbox")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                Spacer()
                if let inbox = viewModel.inboxLabel {
                    Text(inbox)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if viewModel.waitingForJo {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            // Top to bottom, one at a time: a step runs, settles into its count or its tick,
            // and only then does the next start. The finished rows stay up while Jo is awaited.
            ForEach(Array(viewModel.steps.enumerated()), id: \.offset) { index, step in
                stepRow(step, state: viewModel.state(of: index))
                    .transition(.opacity)
                Divider()
            }
            if viewModel.waitingForJo {
                Divider()
                Text("Jo is about to say hello.")
                    .font(.system(size: 17))
                    .foregroundStyle(OnboardingTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .transition(.opacity)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    /// A tally step reads as a phase while it runs and as its number once done; a plain
    /// phase reads as a phase throughout.
    @ViewBuilder private func stepRow(
        _ step: OnboardingPreparingViewModel.Step,
        state: OnboardingPreparingViewModel.PhaseState
    ) -> some View {
        if state == .done, let count = viewModel.count(for: step), let title = step.countTitle {
            CountRow(title: title, count: count)
        } else {
            PhaseRow(title: step.runningTitle, state: state)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
    }
}

// MARK: - Chrome

/// The bead gradient from the recording and permission screens, copied rather than
/// shared — the rule those screens set is that each keeps its own content.
private enum PreparingChrome {
    static let gradient = LinearGradient(
        stops: [
            .init(color: Color(white: 0.82), location: 0),
            .init(color: Color(white: 0.72), location: 0.30),
            .init(color: Color(white: 0.60), location: 0.55),
            .init(color: Color(white: 0.48), location: 0.78),
            .init(color: Color(white: 0.56), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// For the spinner and the track, which take a colour rather than a style.
    static let mid = Color(white: 0.62)
}

// MARK: - Rows

/// One line of the inbox tally, compact past a thousand ("10.5K").
private struct CountRow: View {
    let title: String
    /// Nil draws a spinner in the number's place.
    let count: Int?

    var body: some View {
        HStack(spacing: 12) {
            // The same tick as a finished phase, so the card reads as one list.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(PreparingChrome.gradient)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                .frame(width: 22, height: 22)
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(OnboardingTheme.textPrimary)
            Spacer(minLength: 12)
            if let count {
                Text(count, format: .number.notation(.compactName).precision(.fractionLength(0...1)))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.25), value: count)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(PreparingChrome.mid)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: count == nil)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct PhaseRow: View {
    let title: String
    let state: OnboardingPreparingViewModel.PhaseState

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 22, height: 22)

            Text(title)
                .font(.system(size: 17, weight: state == .running ? .semibold : .regular))
                .foregroundStyle(state == .pending ? OnboardingTheme.textSecondary : OnboardingTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .opacity(state == .pending ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(PreparingChrome.gradient)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(PreparingChrome.mid)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 17))
                .foregroundStyle(OnboardingTheme.textSecondary.opacity(0.5))
        }
    }
}

// MARK: - Bar

/// Fractional, so the fill never stops — `OnboardingProgressBar` steps and eases.
private struct PreparingProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PreparingChrome.mid.opacity(0.18))
                Capsule()
                    .fill(PreparingChrome.gradient)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            }
        }
        .frame(height: 8)
        .accessibilityIdentifier("onboarding_preparing_progress_bar")
    }
}

// MARK: - Component

@MainActor
struct OnboardingPreparingViewComponent {
    @ViewBuilder
    /// The counts seed the tally before the cache answers; previews have no cache.
    static func make(
        onNext: @escaping () -> Void,
        unread: Int? = nil, newsletters: Int? = nil, spam: Int? = nil
    ) -> some View {
        let viewModel = OnboardingPreparingViewModel()
        viewModel.unreadCount = unread
        viewModel.newsletterCount = newsletters
        viewModel.spamCount = spam
        return OnboardingPreparingView(
            viewModel: viewModel,
            interactor: OnboardingPreparingViewInteractor(onNext: onNext)
        )
    }
}

// MARK: - View model

@MainActor
final class OnboardingPreparingViewModel: ViewModel {
    enum PhaseState { case done, running, pending }

    /// The rows, in the order they run. The first three settle into a number.
    enum Step: Hashable {
        case unread, newsletters, spam, handing

        var runningTitle: String {
            switch self {
            case .unread: return "Reading your unread mail"
            case .newsletters: return "Finding newsletters"
            case .spam: return "Checking for spam"
            case .handing: return "Handing it to Jo"
            }
        }

        /// Nil for a step that is only ever a phase.
        var countTitle: String? {
            switch self {
            case .unread: return "Unread"
            case .newsletters: return "Newsletters found"
            case .spam: return "Spam found"
            case .handing: return nil
            }
        }
    }

    @Published var steps: [Step] = [.unread, .newsletters, .spam, .handing]

    /// `steps.count` once every step is done.
    @Published var index: Int = 0

    @Published var fraction: Double = 0

    /// The bar is done and the screen is waiting on Jo's first word.
    @Published var waitingForJo = false

    /// The tally, each nil until its step settles. Spam never reaches the cache
    /// (`in:inbox` only), so `spamCount` stays nil unless something else supplies it.
    @Published var unreadCount: Int?
    @Published var newsletterCount: Int?
    @Published var spamCount: Int?

    /// The address, or "N inboxes" past one; nil with nothing connected.
    @Published var inboxLabel: String?

    func state(of position: Int) -> PhaseState {
        if position < index { return .done }
        if position == index { return .running }
        return .pending
    }

    func count(for step: Step) -> Int? {
        switch step {
        case .unread: return unreadCount
        case .newsletters: return newsletterCount
        case .spam: return spamCount
        case .handing: return nil
        }
    }
}

// MARK: - Interactor

@MainActor
final class OnboardingPreparingViewInteractor: ViewModelInteractor<OnboardingPreparingViewModel> {
    @Injected(\.connections) private var connections
    @Injected(\.voiceCall) private var voiceCall
    @Injected(\.realtimeService) private var realtimeService

    /// The bar only. The screen outlives it by however long Jo takes to speak.
    static let total: Double = 2.0

    /// How long to wait on Jo after the bar before dismissing anyway — a dial that failed
    /// must not strand anyone here.
    static let graceAfterBar: Double = 8.0

    /// Shown when the cache has not answered by the end of a step; a real count that
    /// lands later replaces it.
    private static let unreadStandIn = 12
    private static let newsletterStandIn = 4

    private let onNext: () -> Void
    private var advanced = false
    private var ticker: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init()
    }

    @CancellableBuilder
    override func onViewAppear(viewModel: OnboardingPreparingViewModel) -> [AnyCancellable] {
        super.onViewAppear(viewModel: viewModel)
        nameTheInbox(viewModel: viewModel)
        readCache(viewModel: viewModel)
        startClock(viewModel: viewModel)
    }

    override func onViewDisappear(viewModel: OnboardingPreparingViewModel) {
        super.onViewDisappear(viewModel: viewModel)
        ticker?.cancel()
        ticker = nil
        reader?.cancel()
        reader = nil
    }

    /// The address, or a count past one — a list of addresses wraps.
    private func nameTheInbox(viewModel: OnboardingPreparingViewModel) {
        let accounts = connections.gmailAccounts
        guard !accounts.isEmpty else { return }
        viewModel.inboxLabel = accounts.count == 1 ? accounts[0] : "\(accounts.count) inboxes"
    }

    /// The cache, polled off the clock so a slow read never holds a row. Whatever has
    /// landed by the time a step ends is what it shows.
    private func readCache(viewModel: OnboardingPreparingViewModel) {
        reader?.cancel()
        reader = Task { @MainActor [weak self, weak viewModel] in
            while let self, let viewModel, !Task.isCancelled {
                let store = Container.shared.mailStore()
                let unread = await store.inboxUnread()
                let newsletters = await store.inboxLabelCount("CATEGORY_PROMOTIONS")
                guard !Task.isCancelled else { return }
                if let unread { viewModel.unreadCount = unread.count }
                // A real zero counts; it only never overwrites a value already shown.
                if let newsletters, viewModel.newsletterCount == nil || newsletters > 0 {
                    viewModel.newsletterCount = newsletters
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// A step that ends without its number gets one, so the row reads as found.
    private func settle(_ step: OnboardingPreparingViewModel.Step, viewModel: OnboardingPreparingViewModel) {
        switch step {
        case .unread where viewModel.unreadCount == nil:
            viewModel.unreadCount = Self.unreadStandIn
        case .newsletters where viewModel.newsletterCount == nil:
            viewModel.newsletterCount = Self.newsletterStandIn
        default:
            break
        }
    }

    /// `deferOpening` holds the greeting and mic until `finish` calls `speakOpening()`. It must
    /// follow `connect()`, which builds the client it forwards to.
    private func placeTheCall() {
        guard !realtimeService.isConversing else { return }
        UserDefaults.standard.set(true, forKey: FullDuplexConfig.pendingGreetingKey)
        Task {
            await realtimeService.connect()
            realtimeService.deferOpening()
            voiceCall.dial(announcingConnect: false)
        }
    }

    /// A `Task` rather than a `Timer` publisher because it has to end.
    private func startClock(viewModel: OnboardingPreparingViewModel) {
        ticker?.cancel()
        let steps = viewModel.steps
        let step = Self.total / Double(steps.count)
        ticker = Task { @MainActor [weak self, weak viewModel] in
            for position in 0..<steps.count {
                guard let self, let viewModel, !Task.isCancelled else { return }
                viewModel.index = position
                withAnimation(.linear(duration: step)) {
                    viewModel.fraction = Double(position + 1) / Double(steps.count)
                }
                // Halfway, not at the top: a call placed on appear was up well before the
                // bar ended and left Jo waiting on the flow.
                if position == steps.count / 2 { self.placeTheCall() }
                try? await Task.sleep(for: .seconds(step))
                self.settle(steps[position], viewModel: viewModel)
            }
            guard let self, let viewModel, !Task.isCancelled else { return }
            // Every row reads done while the screen waits on Jo.
            viewModel.index = steps.count
            self.reader?.cancel()
            await self.waitForJo(viewModel: viewModel)
            guard !Task.isCancelled else { return }
            self.advance(viewModel: viewModel)
        }
    }

    /// Ask Jo to speak, then hold the screen until she does. Asked only once the session exists: on
    /// a dialling session `speakOpening` would open the mic while this screen is up. Idempotent.
    private func waitForJo(viewModel: OnboardingPreparingViewModel) async {
        guard realtimeService.isConversing else { return }
        viewModel.waitingForJo = true
        let deadline = Date().addingTimeInterval(Self.graceAfterBar)

        while realtimeService.sessionState == .connecting,
              Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled else { return }
        realtimeService.speakOpening()

        while !realtimeService.openingSpoken, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
        }
        if !realtimeService.openingSpoken {
            RealtimeLog.log("onboarding: Jo did not speak within the grace — going anyway")
        }
    }
}

extension OnboardingPreparingViewInteractor: OnboardingPreparingViewHandler {
    func advance(viewModel: OnboardingPreparingViewModel) {
        guard !advanced else { return }
        advanced = true
        onNext()
    }
}

#if DEBUG
import Prefire

#Preview("OnboardingPreparingView") {
    PreviewOnboardingPreparingHost()
        .snapshot(delay: 0.5)
}
#endif
