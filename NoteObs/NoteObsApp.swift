import SwiftUI

/// Entry point. `--verify` runs the regression suite and exits before any UI or folder access,
/// so the checks never touch the notes folder the user selected.
@main
struct NoteObsEntrypoint {
    static func main() {
        if NotesVerification.isRequested {
            NotesVerification.runAndExit()
        }
        // Before AppContainer exists: its view model opens the recovery directory on creation.
        RecoveryStore.adoptLegacyDirectory()
        NoteObsApplication.main()
    }
}

struct NoteObsApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let container = AppContainer.shared

    var body: some Scene {
        Settings {
            SettingsView(settings: container.settings)
        }
    }
}
