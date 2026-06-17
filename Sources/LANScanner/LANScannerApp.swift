import AppKit
import SwiftUI

@main
struct LANScannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appearance = AppearanceSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appearance)
                .preferredColorScheme(appearance.preferredColorScheme)
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
