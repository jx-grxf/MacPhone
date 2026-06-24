import SwiftUI

struct DetailView: View {
    let section: DeviceSection
    let store: DeviceStore
    let ble: BLEBridgeService

    var body: some View {
        Group {
            switch section {
            case .overview:
                OverviewView(store: store)
            case .setup:
                SetupView(store: store)
            case .android:
                DeviceListView(title: "Android", devices: store.androidDevices, store: store, allowsAdd: true)
            case .ios:
                DeviceListView(title: "iOS Simulator", devices: store.iosDevices, store: store, allowsAdd: false)
            case .bluetooth:
                BluetoothBridgeView(ble: ble)
            }
        }
        .navigationTitle(section.title)
    }
}

private struct OverviewView: View {
    let store: DeviceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    MetricTile(title: "Android", value: store.androidDevices.count, symbol: "app.badge")
                    MetricTile(title: "iOS", value: store.iosDevices.count, symbol: "iphone")
                    MetricTile(title: "Issues", value: store.issues.count, symbol: "exclamationmark.triangle")
                }

                if store.isRefreshing {
                    ProgressView("Refreshing devices")
                }

                if !store.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Setup Issues")
                            .font(.headline)

                        ForEach(store.issues) { issue in
                            Label(issue.message, systemImage: issue.severity.symbol)
                                .foregroundStyle(issue.severity.foregroundStyle)
                        }
                    }
                }

                DeviceRowsView(title: "Recent Devices", devices: store.devices)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Compact, intrinsically-sized device list for embedding inside a ScrollView.
/// `Table` has no intrinsic height and collapses/misbehaves inside a ScrollView,
/// so the overview uses plain rows instead.
private struct DeviceRowsView: View {
    let title: String
    let devices: [MobileDevice]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            if devices.isEmpty {
                ContentUnavailableView(
                    "No Devices",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("Refresh after installing Android Studio or Xcode runtimes.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        DeviceRow(device: device)
                        if index < devices.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct DeviceRow: View {
    let device: MobileDevice

    var body: some View {
        HStack(spacing: 12) {
            Label(device.name, systemImage: device.platform.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(device.runtime)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(device.state)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(device.displayIdentifier)
                .foregroundStyle(.tertiary)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MetricTile: View {
    let title: String
    let value: Int
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 150, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DeviceListView: View {
    let title: String
    let devices: [MobileDevice]
    let store: DeviceStore
    var allowsAdd: Bool = false

    @State private var showAddSheet = false

    private var showsHeadlessToggle: Bool {
        allowsAdd || devices.contains { $0.platform == .android }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if showsHeadlessToggle {
                    ToolbarItem(placement: .automatic) {
                        Toggle("Headless", isOn: Binding(
                            get: { store.bootHeadless },
                            set: { store.bootHeadless = $0 }
                        ))
                        .help("Boot new Android emulators without a window.")
                    }
                }
                if allowsAdd {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.provisionFinished = false
                            store.provisionError = nil
                            store.provisionLog = []
                            showAddSheet = true
                        } label: {
                            Label("Add Emulator", systemImage: "plus")
                        }
                        .disabled(store.isProvisioning)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AndroidProvisionSheet(store: store)
            }
    }

    @ViewBuilder
    private var content: some View {
        if devices.isEmpty {
            ContentUnavailableView {
                Label("No \(title) Devices", systemImage: "rectangle.stack.badge.minus")
            } description: {
                Text(allowsAdd
                    ? "Use “Add Emulator” to download a system image and create one — no Android Studio needed."
                    : "Refresh after installing Android Studio or Xcode runtimes.")
            } actions: {
                if allowsAdd {
                    Button {
                        store.provisionFinished = false
                        store.provisionError = nil
                        store.provisionLog = []
                        showAddSheet = true
                    } label: {
                        Label("Add Emulator", systemImage: "plus")
                    }
                    .disabled(store.isProvisioning)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let error = store.lastActionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.08))
                }

                Table(devices) {
                    TableColumn("Name") { device in
                        Label(device.name, systemImage: device.platform.symbol)
                    }
                    TableColumn("Runtime", value: \.runtime)
                    TableColumn("State") { device in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(device.isRunning ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text(device.state)
                        }
                    }
                    TableColumn("Identifier", value: \.displayIdentifier)
                    TableColumn("") { device in
                        DeviceActionButton(device: device, store: store)
                    }
                    .width(150)
                }
            }
        }
    }
}

private struct DeviceActionButton: View {
    let device: MobileDevice
    let store: DeviceStore
    @State private var confirmingWipe = false

    var body: some View {
        if store.isBusy(device) {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 6) {
                if device.isRunning {
                    Button("Stop") { Task { await store.stop(device) } }
                        .controlSize(.small)
                } else if device.canBoot {
                    Button("Boot") { Task { await store.boot(device) } }
                        .controlSize(.small)
                }

                Menu {
                    if device.canBoot {
                        Button("Cold Boot") { Task { await store.coldBoot(device) } }
                    }
                    if device.isRunning {
                        Button("Stop") { Task { await store.stop(device) } }
                    }
                    if device.platform == .android, device.isRunning {
                        Button("Install BLE Radar") { Task { await store.installBLERadar(onto: device) } }
                    }
                    if device.canWipe {
                        Button("Wipe Data…", role: .destructive) { confirmingWipe = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .confirmationDialog(
                    "Wipe “\(device.name)”?",
                    isPresented: $confirmingWipe,
                    titleVisibility: .visible
                ) {
                    Button("Wipe Data", role: .destructive) { Task { await store.wipe(device) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This erases all data on this \(device.platform.displayName) and resets it to a clean state. This cannot be undone.")
                }
            }
        }
    }
}

