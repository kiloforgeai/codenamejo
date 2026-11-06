#if targetEnvironment(macCatalyst)
import FactoryKit
import SwiftUI
import UIKit

@main
struct JoDesktopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #if !JO_QA
    @ObservedObject private var backend = Container.shared.backend()
    @ObservedObject private var realtime = Container.shared.realtimeService()
    #endif
    @AppStorage(OnboardingState.storageKey) private var onboarded = false
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.system

    init() {
        #if !JO_QA
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { OpenAIKeyService.dropIfLeftByDeletedInstall() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if JO_QA
            DesktopFixtureComponent.make()
            #else
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { Color.clear } else {
            RootViewComponent.make()
                .frame(minWidth: 1040, minHeight: 700)
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in
                    if Container.shared.shortcutActions().handle(url) { return }
                    if MemoDeepLink.matches(url) { Container.shared.voiceLauncher().requestMemo() }
                }
            }
            #endif
        }
        .commands {
            #if !JO_QA
            CommandGroup(after: .appInfo) {
                Button("Start work session") {
                    Container.shared.voiceLauncher().requestLaunch(source: "desktop shortcut")
                }.keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!onboarded || !backend.isSignedIn || realtime.isConversing)
                Button("Mute / unmute microphone") {
                    let session = Container.shared.realtimeService()
                    if session.isConversing { session.setConversationMuted(!session.isMuted) }
                }.keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!realtime.isConversing)
                Button("End work session") {
                    Container.shared.realtimeService().endConversation()
                }.keyboardShortcut(".", modifiers: [.command])
                    .disabled(!realtime.isConversing)
            }
            #endif
        }
    }
}
#endif
