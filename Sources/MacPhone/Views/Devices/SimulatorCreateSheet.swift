import SwiftUI

struct SimulatorCreateSheet: View {
    let store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var runtimeID = ""
    @State private var deviceTypeID = ""
    @State private var bootAfterCreate = true
    @State private var didEditName = false

    private var catalog: SimulatorService.Catalog { store.simulatorCatalog }
    private var job: JobState { store.simulatorJob }
    private var deviceTypes: [SimulatorService.DeviceType] { catalog.deviceTypes(for: runtimeID) }
    private var missingPlatforms: [String] {
        let installed = Set(catalog.runtimes.map { $0.platform == "xrOS" ? "visionOS" : $0.platform })
        return ["iOS", "watchOS", "tvOS", "visionOS"].filter { !installed.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if job.isRunning || job.finished || job.error != nil {
                    progress
                } else if store.isLoadingCatalog {
                    ProgressView("Reading installed runtimes")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    form
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(Design.Space.l)
        }
        .frame(width: 520, height: 420)
        .task {
            store.simulatorJob = JobState()
            await store.loadSimulatorCatalog()
            pickDefaults()
        }
        .onChange(of: runtimeID) { pickDeviceType() }
        .onChange(of: deviceTypeID) {
            if !didEditName { name = deviceTypes.first { $0.id == deviceTypeID }?.name ?? "" }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Runtime", selection: $runtimeID) {
                    ForEach(catalog.runtimes) { runtime in
                        Text(runtime.name).tag(runtime.id)
                    }
                }
                Picker("Device", selection: $deviceTypeID) {
                    ForEach(deviceTypes) { type in
                        Label(type.name, systemImage: type.family.symbol).tag(type.id)
                    }
                }
                TextField("Name", text: $name)
                    .onChange(of: name) { _, value in
                        didEditName = value != deviceTypes.first { $0.id == deviceTypeID }?.name
                    }
                Toggle("Start after creating", isOn: $bootAfterCreate)
            } header: {
                Text("New Simulator")
            }

            if !missingPlatforms.isEmpty {
                Section {
                    ForEach(missingPlatforms, id: \.self) { platform in
                        LabeledContent("\(platform) runtime") {
                            Button("Download") {
                                Task { await store.downloadSimulatorRuntime(platform) }
                            }
                            .disabled(store.isRuntimeDownloadRunning)
                        }
                    }
                } header: {
                    Text("More Runtimes")
                } footer: {
                    Text(store.isRuntimeDownloadRunning
                         ? "Xcode is already downloading a runtime. MacPhone picks it up when it finishes."
                         : "Each runtime is several GB and comes straight from Apple through Xcode.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if job.isRunning {
                Label { Text("Working") } icon: { ProgressView().controlSize(.small) }
            } else if let error = job.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
                if job.error != nil || !job.log.lines.contains(where: { $0.hasPrefix("Created") }) {
                    Button("Back") { store.simulatorJob = JobState(); pickDefaults() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(job.isRunning)
                Button("Create") {
                    Task {
                        await store.createSimulator(
                            .init(name: name, deviceTypeID: deviceTypeID, runtimeID: runtimeID),
                            bootAfterCreate: bootAfterCreate
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(job.isRunning || runtimeID.isEmpty || deviceTypeID.isEmpty
                          || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func pickDefaults() {
        if !catalog.runtimes.contains(where: { $0.id == runtimeID }) {
            runtimeID = catalog.runtimes.first?.id ?? ""
        }
        pickDeviceType()
    }

    private func pickDeviceType() {
        if !deviceTypes.contains(where: { $0.id == deviceTypeID }) {
            // The newest model is listed last by simctl.
            deviceTypeID = deviceTypes.last?.id ?? ""
        }
    }
}
