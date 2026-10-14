import Foundation

/// What a local queue step does to the message cached as the user's current referent.
///
/// A normal step moves onto a message, a page/coaching interstitial pauses between messages,
/// and the terminal feed closes the queue. Keeping those three cases explicit prevents the
/// final message from being resurrected as an anchor after the queue has ended.
enum LocalQueueStandingUpdate: Equatable {
    case publish
    case preserve
    case clear

    static func forInterstitial(_ interstitial: String?) -> Self {
        switch interstitial {
        case "feed": .clear
        case .some: .preserve
        case nil: .publish
        }
    }
}
