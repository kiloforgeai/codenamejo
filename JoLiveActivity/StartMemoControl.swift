import AppIntents
import SwiftUI
import WidgetKit

/// "Leave a Note" in the controls gallery, running `StartMemoIntent` (in both targets so the press
/// opens the app). iOS caches control glyphs: remove and re-add the control after changing it.
struct StartMemoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kiloforge.codenamejo.start-memo") {
            ControlWidgetButton(action: StartMemoIntent()) {
                Label("Leave a Note", image: "OrbPedestalOpen")
            }
        }
        .displayName("Leave a Note")
        .description("Opens Codename Jo and starts recording an offline note.")
    }
}
