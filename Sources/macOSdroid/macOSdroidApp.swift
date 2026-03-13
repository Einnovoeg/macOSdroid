import AppKit
import SwiftUI

/// Defines the dashboard window and the menu bar entry point for the packaged app.
@main
struct macOSdroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("macOSdroid", id: "dashboard") {
            ContentView(model: model)
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
        }
        .defaultSize(width: 940, height: 760)

        MenuBarExtra("macOSdroid", systemImage: "square.stack.3d.up.fill") {
            MenuBarView(model: model)
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
        }
        .menuBarExtraStyle(.window)
    }
}
