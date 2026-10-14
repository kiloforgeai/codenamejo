import CarPlay
import UIKit

/// Whether a car screen is attached, asked of `UIApplication` each time rather than cached: a stale
/// `true` would keep a hot mic with no control surface.
enum CarPlayPresence {
    static var isConnected: Bool {
        UIApplication.shared.connectedScenes.contains { $0 is CPTemplateApplicationScene }
    }
}
