import AppIntents
import SwiftUI
import WidgetKit

/// "Start Voice Command" in the controls gallery, running `StartVoiceSessionIntent`, which is in
/// both targets so the press opens the app.
struct StartVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kiloforge.codenamejo.start-voice") {
            ControlWidgetButton(action: StartVoiceSessionIntent()) {
                // `OrbPedestal` (Media.xcassets) is a custom SF Symbol. Controls render monochrome
                // template glyphs; the system supplies the grey.
                Label("Start Voice Command", image: "OrbPedestal")
            }
        }
        .displayName("Start Voice Command")
        .description("Opens Codename Jo and starts a voice session.")
    }
}
