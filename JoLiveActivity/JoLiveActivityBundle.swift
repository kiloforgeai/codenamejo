import SwiftUI
import WidgetKit

/// The extension's entry point: the voice Live Activity, the two controls and the Home Screen note
/// widget. Everything here builds from `Shared/` and system frameworks alone — no packages.
@main
struct JoLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        VoiceLiveActivity()
        StartVoiceControl()
        StartMemoControl()
        MemoWidget()
    }
}
