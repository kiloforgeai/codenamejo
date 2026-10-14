import Combine
import FactoryKit
import SwiftUI

@MainActor protocol WatchCallViewHandler {
    func start()
    func mute()
    func end()
}

struct WatchCallView<Interactor: ViewWithModelLifecycleObserver<WatchCallViewModel> & WatchCallViewHandler>: View {
    @StateObject var viewModel: WatchCallViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Codename Jo").font(.headline)
                Spacer(minLength: 0)
                Button(action: interactor.start) {
                    ZStack {
                        Circle().fill(WatchCallPalette.silver)
                        Image(systemName: viewModel.active ? "waveform" : "mic.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(WatchCallPalette.onSilver)
                    }.frame(width: 80, height: 80)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.active)
                .accessibilityLabel(viewModel.active ? "Call in progress" : "Talk to Jo")
                Text(viewModel.title).font(.subheadline).fontWeight(.medium)
                if viewModel.active {
                    HStack {
                        Button(action: interactor.mute) {
                            Image(systemName: viewModel.muted ? "mic.slash.fill" : "mic.fill")
                        }
                            .tint(viewModel.muted ? WatchCallPalette.accent : .gray)
                            .foregroundStyle(viewModel.muted ? WatchCallPalette.onSilver : .white)
                            .accessibilityLabel(viewModel.muted ? "Unmute" : "Mute")
                        Button(role: .destructive, action: interactor.end) {
                            Image(systemName: "phone.down.fill")
                        }.tint(.red).accessibilityLabel("End call")
                    }
                } else {
                    Text(viewModel.message).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .bind(observer: interactor, viewModel: viewModel)
    }
}

private enum WatchCallPalette {
    static let accent = Color(white: 0.82)
    static let onSilver = Color(white: 0.08)
    // Matches the iPhone onboarding's silver gradient.
    static let silver = LinearGradient(
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
}

@MainActor
final class WatchCallViewModel: ViewModel {
    @Published var active = false
    @Published var muted = false
    @Published var title = "Tap to talk"
    @Published var message = "Keep your iPhone nearby"
}

@MainActor
final class WatchCallViewInteractor: ViewModelInteractor<WatchCallViewModel>, WatchCallViewHandler {
    @Injected(\.watchCall) private var call

    @CancellableBuilder
    override func onLoad(viewModel: WatchCallViewModel) -> [AnyCancellable] {
        call.$active.assign(to: \.active, on: viewModel)
        call.$muted.assign(to: \.muted, on: viewModel)
        call.$message.assign(to: \.message, on: viewModel)
        call.$status.combineLatest(call.$muted).sink { status, muted in
            switch status {
            case "connecting": viewModel.title = "Connecting…"
            case "listening": viewModel.title = muted ? "Muted" : "Listening"
            case "working": viewModel.title = "Working…"
            case "speaking": viewModel.title = "Jo is speaking"
            case "error": viewModel.title = "Tap to try again"
            default: viewModel.title = "Tap to talk"
            }
        }
    }

    override func onViewAppear(viewModel: WatchCallViewModel) -> [AnyCancellable] {
        call.activate()
        return []
    }
    func start() { call.begin() }
    func mute() { call.toggleMute() }
    func end() { call.end() }
}

@MainActor
struct WatchCallViewComponent {
    static func make() -> some View {
        WatchCallView(viewModel: WatchCallViewModel(), interactor: WatchCallViewInteractor())
    }
}

#if DEBUG
#Preview("WatchCallView") {
    WatchCallViewComponent.make()
}
#endif
