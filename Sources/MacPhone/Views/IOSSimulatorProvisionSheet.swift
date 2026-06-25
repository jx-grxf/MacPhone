import SwiftUI

struct IOSSimulatorProvisionSheet: View {
    let store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = "iPhone Test"
    @State private var runtimeID = ""
    @State private var deviceTypeID = ""
    @State private var bootAfterCreate = true

    private var request: IOSSimulatorProvisioner.Request {
        IOSSimulatorProvisioner.Request(
            name: name,
            deviceTypeIdentifier: deviceTypeID,
            runtimeIdentifier: runtimeID
        )
    }

    private var compatibleDeviceTypes: [IOSSimulatorProvisioner.DeviceType] {
        store.iosCatalog.compatibleDeviceTypes(forRuntimeID: runtimeID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if store.isProvisioningIOS
                    || store.iosProvisionFinished
                    || store.iosProvisionError != nil {
                    progressSection
                } else if store.isLoadingIOSCatalog {
                    ProgressView("Checking Xcode runtimes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.isIOSRuntimeDownloadActive {
                    activeDownloadSection
                } else if store.iosCatalog.runtimes.isEmpty {
                    missingRuntimeSection
                } else {
                    formSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.bar)
        }
        .frame(width: 540, height: 450)
        .task {
            await store.loadIOSCatalog()
            chooseDefaults()
            await store.monitorIOSRuntimeDownload()
        }
        .onChange(of: store.iosCatalog) {
            chooseDefaults()
        }
        .onChange(of: runtimeID) {
            chooseDeviceDefault()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("Add iOS Simulator")
                    .font(.headline)
                Text("Create a device with Apple CoreSimulator")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.isProvisioningIOS)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var formSection: some View {
        Form {
            TextField("Name", text: $name)

            Picker("iOS runtime", selection: $runtimeID) {
                ForEach(store.iosCatalog.runtimes) { runtime in
                    Text(runtime.name).tag(runtime.id)
                }
            }

            Picker("Device", selection: $deviceTypeID) {
                ForEach(compatibleDeviceTypes) { deviceType in
                    Text(deviceType.name).tag(deviceType.id)
                }
            }

            Toggle("Boot after creating", isOn: $bootAfterCreate)
                .help("Open Simulator and boot the new iPhone immediately.")

            LabeledContent("Provider", value: "Apple CoreSimulator")
            Text("MacPhone uses Xcode’s first-party `simctl` tooling. No third-party VM runtime is installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var missingRuntimeSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Simulator runtime required")
                        .font(.title3.weight(.semibold))
                    Text("No iOS runtime is installed in the selected Xcode. MacPhone can download Apple’s current runtime for you.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                infoRow(symbol: "shippingbox", title: "Provider", value: "Apple / Xcode")
                Divider().padding(.leading, 36)
                infoRow(symbol: "externaldrive", title: "Download size", value: "Several GB")
                Divider().padding(.leading, 36)
                infoRow(symbol: "terminal", title: "Installer", value: "xcodebuild")
            }
            .padding(.horizontal, 14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

            Label(
                "Xcode handles installation and verification. No third-party virtualization software is used.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if store.isProvisioningIOS {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                        .foregroundStyle(.secondary)
                } else if let error = store.iosProvisionError {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                } else if store.iosProvisionFinished {
                    Label("iOS simulator created.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Label("Runtime installed.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(store.iosProvisionLog.enumerated()), id: \.offset) { index, line in
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
                .onChange(of: store.iosProvisionLog.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    private var activeDownloadSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Downloading iOS Runtime")
                .font(.title3.weight(.semibold))
            Text("Xcode is continuing the download in the background. You can close or restart MacPhone; do not start a second download.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            Label("MacPhone will detect the runtime automatically when installation finishes.", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if !store.iosProvisionLog.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        store.iosProvisionLog.joined(separator: "\n"),
                        forType: .string
                    )
                } label: {
                    Label("Copy Log", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            Spacer()
            if store.iosProvisionFinished || store.iosProvisionError != nil {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .disabled(store.isProvisioningIOS)
                if store.isIOSRuntimeDownloadActive {
                    Button("Download Running") {}
                        .disabled(true)
                } else if store.iosCatalog.runtimes.isEmpty, !store.isLoadingIOSCatalog {
                    Button {
                        Task {
                            await store.downloadIOSRuntime()
                            chooseDefaults()
                        }
                    } label: {
                        Label("Download Runtime", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isProvisioningIOS)
                } else if !store.iosCatalog.runtimes.isEmpty {
                    Button("Create") {
                        Task {
                            await store.createIOSSimulator(
                                request,
                                bootAfterCreate: bootAfterCreate
                            )
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        store.isProvisioningIOS
                            || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || runtimeID.isEmpty
                            || deviceTypeID.isEmpty
                    )
                }
            }
        }
    }

    private func infoRow(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }

    private func chooseDefaults() {
        if !store.iosCatalog.runtimes.contains(where: { $0.id == runtimeID }) {
            runtimeID = store.iosCatalog.runtimes.first?.id ?? ""
        }
        chooseDeviceDefault()
    }

    private func chooseDeviceDefault() {
        if !compatibleDeviceTypes.contains(where: { $0.id == deviceTypeID }) {
            deviceTypeID = compatibleDeviceTypes.first?.id ?? ""
        }
    }
}
