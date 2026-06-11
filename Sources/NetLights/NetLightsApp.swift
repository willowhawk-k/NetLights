import SwiftUI
import AppKit

@main
struct NetLightsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("NetLights — Network Interface Visualizer") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the default "About NetLights" with our custom window.
            CommandGroup(replacing: .appInfo) { AboutMenuButton() }
            // Replace the default Help with our in-app guide.
            CommandGroup(replacing: .help) { HelpMenuButton() }
        }

        Window("About \(AppInfo.name)", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("\(AppInfo.name) Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 720, height: 640)
    }
}

// MARK: - Menu buttons (need the openWindow environment action)

private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About \(AppInfo.name)") { openWindow(id: "about") }
    }
}

private struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("\(AppInfo.name) Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
    }
}

// MARK: - App lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build-time asset export (used by the release packaging script):
        // render the .icns / Venmo QR, then exit before showing any UI.
        if AssetExport.handleLaunchFlags(CommandLine.arguments) {
            NSApp.terminate(nil)
            return
        }

        // Without a proper .app bundle, SPM executables default to a background
        // activation policy and never show a window. Force foreground mode here.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Set the custom dock icon (rendered from the SwiftUI AppIconView).
        if let icon = AppIconRenderer.dockIcon() {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
