import SwiftUI
import AppKit

@main
struct NetLightsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // Owned here (not in ContentView) so the Help menu can observe live SSID state.
    @StateObject private var monitor = NetworkMonitor()

    var body: some Scene {
        WindowGroup("NetLights — Network Interface Visualizer") {
            ContentView(monitor: monitor)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the default "About NetLights" with our custom window.
            CommandGroup(replacing: .appInfo) { AboutMenuButton() }
            // Replace the default Help with our in-app guide + a sponsor link.
            CommandGroup(replacing: .help) {
                HelpMenuButton()
                LocationHelpMenuButton(monitor: monitor)
                Divider()
                Button(AppInfo.sponsorTitle) {
                    if let url = URL(string: AppInfo.sponsorURL) { NSWorkspace.shared.open(url) }
                }
            }
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

/// Opens System Settings ▸ Privacy & Security ▸ Location Services, for users who
/// declined Location and later want the Wi-Fi network name shown. Greyed out while
/// the SSID is readable (access already granted), per the live monitor state.
private struct LocationHelpMenuButton: View {
    @ObservedObject var monitor: NetworkMonitor
    var body: some View {
        Button("Check Location Privacy Settings…") {
            if let url = URL(string: AppInfo.locationSettingsURL) { NSWorkspace.shared.open(url) }
        }
        .disabled(!monitor.locationHelpAvailable)
        .help("Needed only to show the Wi-Fi network name (SSID).")
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
