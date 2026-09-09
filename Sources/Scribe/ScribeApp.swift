import SwiftUI

@main
struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: appState)
        } label: {
            Image(nsImage: MenuBarIcon.image(recording: appState.isRecording))
        }
        .menuBarExtraStyle(.menu)
    }
}
