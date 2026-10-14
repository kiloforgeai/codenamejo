import BackgroundTasks
import Foundation
import UIKit

/// Keeps the process running while a dispatched job or a background write finishes,
/// whether or not the call that started it is still up.
///
/// Holds a `beginBackgroundTask` assertion (about 30 s off screen) and, for a job started on screen, a
/// `BGContinuedProcessingTask` (minutes, with a cancellable card), which iOS grants only to the foreground app.
@MainActor
enum HangUpRunway {
    /// Run `work` under both holds. Passing `progress` asks for the continued task; it is
    /// what the system card draws.
    static func run<T>(_ title: String, subtitle: String = "", progress: Progress? = nil,
                       _ work: @escaping @MainActor () async -> T) async -> T {
        let inner = Task { await work() }
        let hold = Hold(cancel: { inner.cancel() })
        hold.assertion = UIApplication.shared.beginBackgroundTask(withName: title) { hold.expire() }
        if let progress, UIApplication.shared.applicationState == .active {
            hold.submitContinued(title: title, subtitle: subtitle, progress: progress)
        }
        let result = await withTaskCancellationHandler { await inner.value } onCancel: { inner.cancel() }
        hold.finish(success: !inner.isCancelled)
        return result
    }
}

@MainActor
private final class Hold {
    let cancel: () -> Void
    var assertion = UIBackgroundTaskIdentifier.invalid
    private var continued: BGContinuedProcessingTask?
    private var done = false

    init(cancel: @escaping () -> Void) { self.cancel = cancel }

    /// iOS is taking the time back. The work is cancelled so it records itself as stopped.
    func expire() {
        cancel()
        endAssertion()
    }

    func submitContinued(title: String, subtitle: String, progress: Progress) {
        // One identifier per job: registering the same one twice kills the app. Info.plist
        // permits the `.dispatch.*` wildcard.
        let identifier = (Bundle.main.bundleIdentifier ?? "") + ".dispatch." + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask, let self, !self.done else {
                    task.setTaskCompleted(success: true)
                    return
                }
                continued.progress.totalUnitCount = 1
                continued.progress.addChild(progress, withPendingUnitCount: 1)
                // The user cancelled from the card, or iOS needs the time back.
                continued.expirationHandler = { [weak self] in
                    DispatchQueue.main.async { self?.cancel() }
                }
                self.continued = continued
            }
        }
        guard registered else {
            RealtimeLog.log("runway: \(identifier) is not a permitted identifier")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // A queued request would start after the job it was meant to cover.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            RealtimeLog.log("runway: continued task refused — \(error.localizedDescription)")
        }
    }

    func finish(success: Bool) {
        done = true
        continued?.setTaskCompleted(success: success)
        continued = nil
        endAssertion()
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }
}
