import SwiftUI

/// Clicky — explains what you circle on screen.
/// Menu bar only (LSUIElement = YES), no Dock icon.
@main
struct ClickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("Clicky", systemImage: "cursorarrow.rays") {
            MenuPanelView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Clicky Debug Console", id: "debug-console") {
            DebugConsoleView()
        }
        .defaultSize(width: 780, height: 460)
        .defaultLaunchBehavior(.suppressed)
    }
}
