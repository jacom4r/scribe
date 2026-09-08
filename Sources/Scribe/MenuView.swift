import SwiftUI

struct MenuView: View {
    let state: AppState

    var body: some View {
        Button("Open Recordings Folder") { state.openRecordingsFolder() }
        Button("Quit Scribe") { state.quit() }
            .keyboardShortcut("q")
    }
}
