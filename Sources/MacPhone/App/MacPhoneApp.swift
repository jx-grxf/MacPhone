import SwiftUI

@main
struct MacPhoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MacPhone", id: "main") {
            ContentView(store: appDelegate.store, setup: appDelegate.setup, ble: appDelegate.ble)
                .frame(minWidth: 900, minHeight: 600)
                .environment(appDelegate.updates)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { appDelegate.updates.checkForUpdates() }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Devices") { Task { await appDelegate.store.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.updates)
        }
    }
}

/// Owns the long-lived services. `App` values can be re-created by SwiftUI, and a second
/// Sparkle controller or CoreBluetooth central must never exist.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = DeviceStore()
    let setup = SetupStore()
    let ble = BLEBridgeService()
    let updates = UpdateService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A child that exits while we write its stdin must not kill MacPhone.
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if ble.isMirroring { ble.stopMirror() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
