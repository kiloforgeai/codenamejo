import Foundation

struct LiveBrainRequestError: Error {
    let status: Int
    let serverCode: String?
    var diagnostic: String {
        let known: Set<String> = ["brain_context_too_large", "brain_task_too_large", "brain_request_too_large",
            "invalid_brain_items", "invalid_brain_item", "invalid_brain_item_type", "invalid_brain_history",
            "invalid_request", "brain_session_expired", "brain_profile_changed",
            "brain_request_in_progress_or_uncertain", "brain_request_failed", "not_authorized"]
        return "http=\(status) code=\(serverCode.flatMap { known.contains($0) ? $0 : nil } ?? "unknown")"
    }
}
