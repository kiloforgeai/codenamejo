#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

struct DesktopRenderProbe: UIViewRepresentable {
    let state: RenderedFeedState
    let applied: (RenderedFeedState) -> Void

    func makeUIView(context: Context) -> ProbeView { ProbeView() }

    func updateUIView(_ view: ProbeView, context: Context) {
        guard context.coordinator.pending != state else { return }
        context.coordinator.pending = state
        let coordinator = context.coordinator
        view.observe = { [weak view] in
            guard let view, let window = view.window, !window.isHidden,
                  coordinator.pending == state, coordinator.rendered != state else { return }
            view.superview?.layoutIfNeeded()
            coordinator.rendered = state
            applied(state)
        }
        DispatchQueue.main.async { view.observe?() }
    }

    class ProbeView: UIView {
        var observe: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.observe?() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator {
        var pending: RenderedFeedState?
        var rendered: RenderedFeedState?
    }
}
#endif
