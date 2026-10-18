import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AndroidSDK.customRootKey) private var sdkRoot = ""
    @AppStorage("android.bootWithoutWindow") private var bootWithoutWindow = false

    var body: some View {
        Form {
            Section {
                LabeledContent("SDK folder") {
                    HStack {
                        Text(sdkRoot.isEmpty ? (AndroidSDK.locate()?.root.path ?? "Not found") : sdkRoot)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseSDK)
                    }
                }
                if !sdkRoot.isEmpty {
                    Button("Find Automatically") { sdkRoot = "" }
                }
                Toggle("Start emulators without a window", isOn: $bootWithoutWindow)
                Text("Headless emulators render in software and keep running in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Android")
            } footer: {
                Text("MacPhone looks in ANDROID_HOME, ~/Library/Android/sdk and the Homebrew command-line tools. Pick a folder if your SDK lives elsewhere.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }

    private func chooseSDK() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Android SDK folder (it contains platform-tools and emulator)."
        if panel.runModal() == .OK, let url = panel.url { sdkRoot = url.path }
    }
}

struct UpdatesSettingsView: View {
    @Environment(UpdateService.self) private var updates

    var body: some View {
        @Bindable var updates = updates
        Form {
            Section {
                LabeledContent("Installed", value: Self.versionString)
                if let available = updates.availableUpdateVersion {
                    LabeledContent("Available") {
                        Label(available, systemImage: "arrow.down.circle.fill")
                    }
                }
                Picker("Channel", selection: $updates.channel) {
                    ForEach(UpdateService.Channel.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Check automatically", isOn: $updates.automaticallyChecksForUpdates)
                if let date = updates.lastCheckDate {
                    LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                HStack {
                    Text("Beta builds arrive earlier and may have rough edges.")
                    Spacer()
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }
}
