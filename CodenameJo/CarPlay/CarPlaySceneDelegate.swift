import CarPlay
import FactoryKit
import UIKit

/// The car screen, as a second scene in this process (declared in `Resources/Info.plist`). Uses the
/// windowless delegate pair; the `CPWindow` variants are for navigation apps.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    /// Held for the life of the scene; the scene retains the interface controller but not this
    /// wrapper.
    private var carPlay: CarPlayVoiceController?

    // MARK: - Scene lifecycle

    /// `didConnect:`, not `didConnect:to:`: CarPlay calls the windowless variant for a
    /// non-navigation app, and the window pair compiles but never runs.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        RealtimeLog.log("carplay: scene connected")
        let controller = CarPlayVoiceController(
            interfaceController: interfaceController,
            contentStyle: templateApplicationScene.contentStyle
        )
        carPlay = controller
        controller.start()
        // A call already running off-screen has just changed control surface, and only
        // this scene knows. Nothing about the call itself moves — see the method.
        Container.shared.realtimeService().carPlayConnected()
    }

    /// The car went light or dark. The orb is rendered art, so it has to be drawn again.
    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
        carPlay?.contentStyleDidChange(contentStyle)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        RealtimeLog.log("carplay: scene disconnected")
        carPlay?.stop()
        carPlay = nil
        // The call outlives this scene: `carPlayDisconnected()` hands it to the orb or the Lock
        // Screen card if either can take it, and hangs up otherwise.
        Container.shared.realtimeService().carPlayDisconnected()
    }
}
