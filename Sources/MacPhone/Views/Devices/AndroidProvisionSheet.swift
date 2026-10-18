import SwiftUI

struct AndroidProvisionSheet: View {
    let store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Pixel_9"
    @State private var platform = AndroidProvisioner.platforms[0].id
    @State private var tag = AndroidProvisioner.tags[0].0
    @State private var device = AndroidProvisioner.deviceProfiles[0]
    @State private var bootAfterCreate = true

    private var job: JobState { store.androidJob }
    private var request: AndroidProvisioner.Request {
        .init(name: name, platform: platform, tag: tag, device: device)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if job.isRunning || job.finished || job.error != nil {
                    progress
                } else {
                    form
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(Design.Space.l)
        }
        .frame(width: 520, height: 440)
        .task { if !job.isRunning { store.androidJob = JobState() } }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Picker("Android version", selection: $platform) {
                    ForEach(AndroidProvisioner.platforms) { Text($0.title).tag($0.id) }
                }
                Picker("Image", selection: $tag) {
                    ForEach(AndroidProvisioner.tags, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Hardware profile", selection: $device) {
                    ForEach(AndroidProvisioner.deviceProfiles, id: \.self) { profile in
                        Text(profile.replacingOccurrences(of: "_", with: " ").capitalized).tag(profile)
                    }
                }
                Toggle("Start after creating", isOn: $bootAfterCreate)
            } header: {
                Text("New Emulator")
            } footer: {
                Text("Downloads \(request.systemImagePackage) with sdkmanager and creates the emulator. Images are 1 to 2 GB.")
            }
        }
        .formStyle(.grouped)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if job.isRunning {
                Label { Text("Downloading and creating. Large images take a few minutes.") } icon: { ProgressView().controlSize(.small) }
            } else if let error = job.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Label("\(request.sanitizedName) is ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            LogView(lines: job.log.lines)
        }
        .padding(Design.Space.xl)
    }

    private var footer: some View {
        HStack {
            if !job.log.lines.isEmpty {
                Button("Copy Log") { copyToPasteboard(job.log.text) }
            }
            Spacer()
            if job.finished || job.error != nil {
                if job.error != nil {
                    Button("Back") { store.androidJob = JobState() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else if job.isRunning {
                Button("Hide") { dismiss() }
                    .help("The download keeps running. Open this sheet again to see its progress.")
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await store.createAndroidEmulator(request, bootAfterCreate: bootAfterCreate) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
