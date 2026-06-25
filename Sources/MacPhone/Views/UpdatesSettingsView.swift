import SwiftUI

/// Settings → Updates pane: installed/available version, the stable/beta channel
/// toggle, the automatic-check preference, and a manual "Check Now".
struct UpdatesSettingsView: View {
    @Environment(UpdateService.self) private var updates
    @AppStorage(AppPreferences.testDevicesEnabled) private var testDevicesEnabled = false

    var body: some View {
        @Bindable var updates = updates
        Form {
            Section("Version") {
                LabeledContent("Installed", value: Self.versionString)
                if updates.isUpdateAvailable, let available = updates.availableUpdateVersion {
                    LabeledContent("Available") {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                            Text(available)
                        }
                    }
                }
            }
            Section("Channel") {
                Picker("Update channel", selection: $updates.channel) {
                    ForEach(UpdateService.Channel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Automatic checks") {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                Text("On by default — MacPhone checks in the background and on launch. Turn this off to only check manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let date = updates.lastCheckDate {
                    LabeledContent("Last check", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Test Devices") {
                Toggle("Show test devices in Bluetooth", isOn: $testDevicesEnabled)
                Text("Adds the selectable virtual scooter catalog to the Bluetooth screen. Test devices are disabled by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Check Now") { updates.checkForUpdates() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 460, height: 520)
    }

    /// "0.1.0 (1)" from the bundle's marketing version and build number.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
