import SwiftUI

struct BridgeView: View {
    let ble: BLEBridgeService
    let setup: SetupStore
    let showSetup: () -> Void

    @AppStorage("bridge.showActivity") private var showActivity = false

    var body: some View {
        VStack(spacing: 0) {
            MirrorPath(ble: ble, setup: setup, showSetup: showSetup)
                .padding(Design.Space.xl)

            Divider()

            Group {
                if ble.state.hasDevice {
                    GATTList(ble: ble)
                } else {
                    ScanList(ble: ble)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showActivity {
                Divider()
                LogView(lines: ble.log.suffix(300).map(Self.format), minHeight: 160)
                    .frame(maxHeight: 220)
                    .padding(Design.Space.m)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showActivity.animation(Design.Motion.expand)) {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .help("Show every read, write and notification")

                if ble.state == .idle {
                    Button { ble.startDemo() } label: { Label("Demo Device", systemImage: "wand.and.stars") }
                        .help("A made-up battery device, for trying the emulator path without hardware")
                    Button { ble.startScan() } label: { Label("Scan", systemImage: "magnifyingglass") }
                        .disabled(!ble.isBluetoothReady)
                } else {
                    Button { ble.stopDevice() } label: { Label(stopTitle, systemImage: "stop.circle") }
                }
            }
        }
    }

    private var stopTitle: String {
        switch ble.state {
        case .scanning: "Stop Scan"
        case .connecting: "Cancel"
        case .demo: "Stop Demo"
        default: "Disconnect"
        }
    }

    private static func format(_ entry: BLELogEntry) -> String {
        let arrow = switch entry.direction {
        case .info: " "
        case .outgoing: "→"
        case .incoming: "←"
        case .error: "!"
        }
        return "\(entry.timestamp.formatted(date: .omitted, time: .standard)) \(arrow) \(entry.message)"
    }
}

/// Device → Mac → bridge → emulator, each step with its own state, so it is obvious which
/// link is missing.
private struct MirrorPath: View {
    let ble: BLEBridgeService
    let setup: SetupStore
    let showSetup: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 0) {
                step(
                    "Device",
                    symbol: "sensor.tag.radiowaves.forward",
                    detail: ble.mirrorSourceName ?? (ble.state == .scanning ? "Scanning" : "None yet"),
                    state: ble.state.hasDevice ? .ok : (ble.state == .idle ? .off : .busy)
                )
                arrow
                step(
                    "Mac",
                    symbol: "macbook",
                    detail: ble.bluetoothProblem == nil ? "Bluetooth on" : "Bluetooth unavailable",
                    state: ble.bluetoothProblem == nil ? (ble.isBluetoothReady ? .ok : .busy) : .problem
                )
                arrow
                step(
                    "Bridge",
                    symbol: "arrow.left.arrow.right",
                    detail: ble.bridgeProcess.lastError != nil ? "Stopped" : ble.bridgeProcess.statusLine,
                    state: ble.bridgeProcess.lastError != nil ? .problem : (ble.isMirroring ? .ok : .off)
                )
                arrow
                step(
                    "Emulator",
                    symbol: "smartphone",
                    detail: ble.isEmulatorConnected ? "App connected" : (ble.isMirroring ? "Waiting for an app" : "Off"),
                    state: ble.isEmulatorConnected ? .ok : (ble.isMirroring ? .busy : .off)
                )
            }
            .padding(.vertical, Design.Space.l)

            Divider()

            HStack(spacing: Design.Space.m) {
                // No vertical fixedSize here: in an HStack it lets the text report a huge
                // ideal height, which pushes the whole window content under the title bar.
                Text(message)
                    .font(.callout)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Spacer(minLength: Design.Space.m)
                if !setup.bridgeReady, !setup.dependencies.isEmpty {
                    Button("Open Setup", action: showSetup)
                }
                if ble.isMirroring {
                    Button("Stop Mirror") { ble.stopMirror() }
                } else {
                    Button("Mirror to Emulator") { ble.startMirror() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!setup.bridgeReady)
                }
            }
            .padding(Design.Space.l)
        }
    }

    private var problem: String? {
        ble.bluetoothProblem ?? ble.bridgeProcess.lastError ?? ble.server.lastError
            ?? (setup.bridgeReady || setup.dependencies.isEmpty ? nil : "The bridge needs Python and Bumble. Setup installs both.")
    }

    private var message: String {
        if let problem { return problem }
        if ble.isEmulatorConnected {
            return "An app in the emulator is connected to \(ble.mirrorSourceName ?? "the device"). Reads, writes and notifications go straight through."
        }
        if ble.isMirroring {
            return "In the emulator, scan from your app as usual. The device appears under its real name. Connect from the app or nRF Connect, not from Android Settings."
        }
        if ble.state.hasDevice {
            return "Start the Android emulator, then mirror \(ble.mirrorSourceName ?? "the device") into it."
        }
        return "Connect a BLE device below, or start the demo device. Without one, mirroring starts the demo."
    }

    private enum StepState { case off, busy, ok, problem }

    private func step(_ title: String, symbol: String, detail: String, state: StepState) -> some View {
        VStack(spacing: Design.Space.s) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(state == .off ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .frame(width: 44, height: 36)
                Image(systemName: badge(state))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint(state))
                    .background(Circle().fill(Design.cardFill).padding(-1))
                    .offset(x: 4, y: 2)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 14)
    }

    private func badge(_ state: StepState) -> String {
        switch state {
        case .off: "circle.dashed"
        case .busy: "ellipsis.circle.fill"
        case .ok: "checkmark.circle.fill"
        case .problem: "exclamationmark.circle.fill"
        }
    }

    private func tint(_ state: StepState) -> Color {
        switch state {
        case .off: .secondary
        case .busy: .orange
        case .ok: .green
        case .problem: .red
        }
    }
}

private struct ScanList: View {
    let ble: BLEBridgeService

    var body: some View {
        if ble.discovered.isEmpty {
            ContentUnavailableView {
                Label(ble.isScanning ? "Looking for Devices" : "No Device", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text(ble.isScanning
                     ? "Wake the device or put it in pairing mode. Only Bluetooth LE devices show up."
                     : "Scan for a Bluetooth LE device near this Mac, or use the demo device.")
            } actions: {
                if !ble.isScanning {
                    Button("Scan") { ble.startScan() }
                        .disabled(!ble.isBluetoothReady)
                }
            }
        } else {
            Table(ble.discovered) {
                TableColumn("Name") { peripheral in
                    Text(peripheral.displayName)
                        .foregroundStyle(peripheral.name.isEmpty ? .secondary : .primary)
                }
                TableColumn("Signal") { peripheral in
                    Text("\(peripheral.rssi) dBm").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Advertised services") { peripheral in
                    Text(peripheral.advertisedServices.isEmpty ? "–" : peripheral.advertisedServices.joined(separator: ", "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                TableColumn("") { peripheral in
                    Button("Connect") { ble.connect(peripheral.id) }
                        .disabled(!peripheral.isConnectable)
                }
                .width(80)
            }
        }
    }
}

private struct GATTList: View {
    let ble: BLEBridgeService

    var body: some View {
        if ble.services.isEmpty {
            ProgressView(ble.state.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .listStyle(.inset)
        }
    }
}

private struct CharacteristicRow: View {
    let ble: BLEBridgeService
    let characteristic: BLECharacteristic
    @State private var payload = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(characteristic.displayName)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
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
                    .textSelection(.enabled)
            }

            HStack(spacing: Design.Space.s) {
                if characteristic.canRead {
                    Button("Read") { ble.read(characteristic) }
                }
                if characteristic.canNotify {
                    Toggle("Notify", isOn: Binding(
                        get: { characteristic.isNotifying },
                        set: { ble.setNotify($0, for: characteristic) }
                    ))
                    .toggleStyle(.button)
                }
                if characteristic.canWrite {
                    TextField("Hex, e.g. 01ff", text: $payload)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .frame(maxWidth: 200)
                        .onSubmit(send)
                    Button("Write", action: send)
                        .disabled(payload.isEmpty)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, Design.Space.xs)
    }

    private func send() {
        guard !payload.isEmpty else { return }
        ble.write(hex: payload, to: characteristic, withResponse: characteristic.properties.contains("write"))
        payload = ""
    }
}
