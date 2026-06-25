import SwiftUI
import CoreBluetooth

struct BluetoothBridgeView: View {
    let ble: BLEBridgeService
    @AppStorage(AppPreferences.testDevicesEnabled) private var testDevicesEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            bridgeServerBar

            if ble.connectedPeripheralID != nil {
                connectedView
            } else {
                scanView
            }

            ActivityLogView(entries: ble.log, onClear: ble.clearLog)
                .frame(minHeight: 140, maxHeight: 200)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { ble.start() }
        .onChange(of: testDevicesEnabled) { _, enabled in
            if !enabled, ble.scooterActive {
                ble.leaveCurrentDevice()
            }
        }
    }

    private var stopLabel: String {
        if ble.scooterActive { return "Stop Scooter" }
        if ble.demoActive { return "Stop Demo" }
        return "Disconnect"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("BLE Bridge", systemImage: "dot.radiowaves.left.and.right")
                    .font(.title2.weight(.semibold))
                Text(ble.statusMessage)
                    .font(.callout)
                    .foregroundStyle(ble.isBluetoothReady ? Color.secondary : Color.red)
            }

            Spacer()

            if ble.demoActive || ble.scooterActive || ble.connectedPeripheralID != nil {
                // One control to fully reset back to scanning, whatever the state.
                Button(role: .destructive) { ble.leaveCurrentDevice() } label: {
                    Label(stopLabel, systemImage: "xmark.circle")
                }
            } else if ble.isScanning {
                Button { ble.stopScan() } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
            } else {
                if testDevicesEnabled {
                    Button { ble.startVirtualScooter() } label: {
                        Label("Test Scooter", systemImage: "scooter")
                    }
                    .help("Publish an emulated Xiaomi M365 scooter for testing with XiaoDash.")
                }
                Button { ble.startDemo() } label: {
                    Label("Demo Device", systemImage: "wand.and.stars")
                }
                .help("Publish a synthetic battery device so you can test the emulator path without real hardware.")
                Button { ble.startScan() } label: {
                    Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!ble.isBluetoothReady)
            }
        }
    }

    // MARK: Bridge server

    private var bridgeServerBar: some View {
        let live = ble.isMirroring && ble.server.clientCount > 0
        return HStack(spacing: 10) {
            Image(systemName: live ? "antenna.radiowaves.left.and.right.circle.fill"
                                   : (ble.isMirroring ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"))
                .foregroundStyle(live ? Color.green : (ble.isMirroring ? Color.orange : Color.secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Emulator Mirror")
                        .font(.subheadline.weight(.medium))
                    if live {
                        statusChip("CONNECTED", .green, filled: true)
                    } else if ble.isMirroring {
                        statusChip("STARTING…", .orange, filled: false)
                    } else {
                        statusChip("OFF", .secondary, filled: false)
                    }
                }
                Text(mirrorSubtitle)
                    .font(.caption)
                    .foregroundStyle(ble.bridgeProcess.lastError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            if ble.isMirroring {
                Button("Stop Mirror") { ble.stopEmulatorMirror() }
                    .controlSize(.small)
            } else {
                Button {
                    ble.startEmulatorMirror()
                } label: {
                    Label("Mirror to Emulator", systemImage: "play.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("One click: brings up the server, uses your connected device (or the demo), and launches the netsim bridge.")
            }
        }
        .padding(12)
        .background(live ? Color.green.opacity(0.12) : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusChip(_ text: String, _ color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(filled ? AnyShapeStyle(color) : AnyShapeStyle(.quaternary), in: Capsule())
    }

    private var mirrorSubtitle: String {
        if let error = ble.bridgeProcess.lastError { return error }
        if ble.isMirroring {
            if ble.server.clientCount > 0 {
                return "Mirroring \(ble.mirrorSourceLabel) → emulator. In the emulator, open a BLE client (e.g. nRF Connect, not Android Settings) and connect to “MacPhone Bridge”."
            }
            return ble.bridgeProcess.statusLine
        }
        return "Off. Press “Mirror to Emulator” to expose a device to the Android emulator."
    }

    // MARK: Scan

    private var scanView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Nearby Peripherals")
                    .font(.headline)
                if ble.isScanning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("\(ble.discovered.count) found")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if ble.discovered.isEmpty {
                ContentUnavailableView(
                    ble.isScanning ? "Searching…" : "No Peripherals",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text(ble.isBluetoothReady
                        ? "Press Scan to look for advertising BLE devices."
                        : ble.statusMessage)
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Table(ble.discovered) {
                    TableColumn("Name") { peripheral in
                        Text(peripheral.displayName)
                    }
                    TableColumn("RSSI") { peripheral in
                        Text("\(peripheral.rssi) dBm").monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Services") { peripheral in
                        Text(peripheral.advertisedServices.isEmpty ? "—" : peripheral.advertisedServices.joined(separator: ", "))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("") { peripheral in
                        Button("Connect") { ble.connect(peripheral.id) }
                            .disabled(!peripheral.isConnectable)
                    }
                    .width(90)
                }
            }
        }
    }

    // MARK: Connected GATT

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GATT Services")
                    .font(.headline)
                Spacer()
                Button {
                    ble.leaveCurrentDevice()
                } label: {
                    Label("\(stopLabel) & Scan", systemImage: "arrow.left")
                }
                .controlSize(.small)
            }

            if ble.services.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Discovering services…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            } else {
                List {
                    ForEach(ble.services) { service in
                        Section(service.displayName) {
                            ForEach(service.characteristics) { characteristic in
                                CharacteristicRow(ble: ble, characteristic: characteristic)
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
    }
}

private struct CharacteristicRow: View {
    let ble: BLEBridgeService
    let characteristic: BLECharacteristic
    @State private var writeHex = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(characteristic.displayName)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Text(characteristic.properties.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let value = characteristic.lastValueHex, !value.isEmpty {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                if characteristic.properties.contains("read") {
                    Button("Read") { ble.readValue(for: characteristic) }
                        .controlSize(.small)
                }
                if characteristic.properties.contains("notify") || characteristic.properties.contains("indicate") {
                    Button(characteristic.isNotifying ? "Unsubscribe" : "Subscribe") {
                        ble.setNotify(!characteristic.isNotifying, for: characteristic)
                    }
                    .controlSize(.small)
                }
                if canWrite {
                    TextField("hex payload", text: $writeHex)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .frame(maxWidth: 200)
                    Button("Write") {
                        ble.write(hex: writeHex, to: characteristic, withResponse: characteristic.properties.contains("write"))
                        writeHex = ""
                    }
                    .controlSize(.small)
                    .disabled(writeHex.isEmpty)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var canWrite: Bool {
        characteristic.properties.contains("write") || characteristic.properties.contains("writeNR")
    }
}

private struct ActivityLogView: View {
    let entries: [BLELogEntry]
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Button("Clear", action: onClear)
                    .controlSize(.small)
                    .disabled(entries.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: entry.direction.symbol)
                                    .foregroundStyle(color(for: entry.direction))
                                    .font(.caption)
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: entries.count) { _, _ in
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(for direction: BLELogEntry.Direction) -> Color {
        switch direction {
        case .info: .secondary
        case .outgoing: .blue
        case .incoming: .green
        case .error: .red
        }
    }
}
