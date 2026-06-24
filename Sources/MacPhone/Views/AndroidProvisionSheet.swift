import SwiftUI

/// Configures and runs the "Add Android emulator" flow: pick an API level / profile,
/// then download the system image and create the AVD with live progress.
struct AndroidProvisionSheet: View {
    let store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Pixel_New"
    @State private var apiLevel = AndroidProvisioner.apiLevels.first ?? 35
    @State private var tag = "google_apis"
    @State private var device = "pixel_7"
    @State private var bootAfterCreate = true

    private var abi: String {
        // Apple silicon runs arm64 images natively; Intel Macs need x86_64.
        #if arch(arm64)
        "arm64-v8a"
        #else
        "x86_64"
        #endif
    }

    private var request: AndroidProvisioner.Request {
        AndroidProvisioner.Request(name: name, apiLevel: apiLevel, tag: tag, abi: abi, device: device)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Android Emulator")
                .font(.title2.weight(.semibold))

            if store.isProvisioning || !store.provisionLog.isEmpty {
                progressSection
            } else {
                formSection
            }

            Divider()
            footer
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 460, idealHeight: 520)
    }

    private var formSection: some View {
        Form {
            TextField("Name", text: $name)
                .help("Letters, numbers, _ - . only. Spaces become underscores.")

            Picker("Android API", selection: $apiLevel) {
                ForEach(AndroidProvisioner.apiLevels, id: \.self) { level in
                    Text("API \(level)").tag(level)
                }
            }

            Picker("Image", selection: $tag) {
                Text("Google APIs").tag("google_apis")
                Text("Google Play").tag("google_apis_playstore")
                Text("AOSP (no Google)").tag("default")
            }

            Picker("Device profile", selection: $device) {
                ForEach(AndroidProvisioner.deviceProfiles, id: \.self) { profile in
                    Text(profile).tag(profile)
                }
            }

            LabeledContent("ABI", value: abi)
            LabeledContent("Package", value: request.systemImagePackage)
                .font(.caption.monospaced())

            Toggle("Boot after creating", isOn: $bootAfterCreate)
                .help("Start the emulator as soon as it is created.")
        }
        .formStyle(.grouped)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if store.isProvisioning {
                    ProgressView().controlSize(.small)
                    Text("Downloading & creating… this can take a few minutes.")
                        .foregroundStyle(.secondary)
                } else if let error = store.provisionError {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                } else if store.provisionFinished {
                    Label("Emulator created.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(store.provisionLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: store.provisionLog.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if !store.provisionLog.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.provisionLog.joined(separator: "\n"), forType: .string)
                } label: { Label("Copy Log", systemImage: "doc.on.doc") }
                    .controlSize(.small)
            }
            Spacer()
            if store.provisionFinished || store.provisionError != nil {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .disabled(store.isProvisioning)
                Button("Download & Create") {
                    Task { await store.createAndroidEmulator(request, bootAfterCreate: bootAfterCreate) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isProvisioning || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
