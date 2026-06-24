import SwiftUI

@main
struct MacPhoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DeviceStore()
    @State private var ble = BLEBridgeService()
    @State private var updates = UpdateService()

    var body: some Scene {
        WindowGroup("MacPhone", id: "main") {
            ContentView(store: store, ble: ble)
                .frame(minWidth: 980, minHeight: 640)
                .environment(updates)
                .task {
                    await store.refresh()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Devices") {
                    Task {
                        await store.refresh()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
            }
        }

        Settings {
            UpdatesSettingsView()
                .environment(updates)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
