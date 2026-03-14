import SwiftUI

@main
struct TotCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let container = AppContainer.shared

    var body: some Scene {
        Settings {
            SettingsView(settings: container.settings)
        }
    }
}
