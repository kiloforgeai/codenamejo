import Foundation

/// Whether a dispatch report may become context-only after waiting for a speaking gap.
///
/// A report launched from an email queue is owed a queue-ordered return. If that queue has
/// no N+2 step, it waits for the next quiet beat instead of falling through the ordinary
/// twenty-second expiry and being injected silently.
enum DispatchReportDelivery: Equatable {
    case standard
    case nextQuietBeat

    var mayExpireUnspoken: Bool { self == .standard }
}
