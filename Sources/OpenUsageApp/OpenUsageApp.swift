import OpenUsage
import SwiftUI

@main
struct OpenUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar app: the status item and custom panel are AppKit-owned (see StatusItemController),
        // so no window scene is wanted. `Settings` gives SwiftUI a valid scene without creating
        // an activation window. Its command would open that empty window on ⌘,, so it's removed:
        // the panel holds Settings. The default menu stays, because text fields need its Edit commands.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}
