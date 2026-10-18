import Foundation
import Observation
@preconcurrency import CoreBluetooth

/// The Mac side of the bridge. It connects to a real BLE peripheral as a CoreBluetooth
/// central on the built-in radio and relays its GATT to the netsim bridge.
///
/// macOS does not expose the internal controller's HCI, so the mirror works one level up:
/// services, characteristics and their values. A device that secures its traffic in the
/// application layer works; one that needs link-layer pairing does not.
@Observable
@MainActor
final class BLEBridgeService: NSObject {
    private(set) var state: BLEConnectionState = .idle
    private(set) var managerState: CBManagerState = .unknown
    private(set) var discovered: [DiscoveredPeripheral] = []
    private(set) var services: [BLEService] = []
    private(set) var log: [BLELogEntry] = []

    let server = BLEBridgeServer()
    let bridgeProcess = NetsimBridgeProcess()

    private var central: CBCentralManager?
    /// The one peripheral we are connecting to, connected to, or reconnecting to. Delegate
    /// callbacks for any other peripheral are stale and ignored.
    private var target: CBPeripheral?
    private var peripheralCache: [UUID: CBPeripheral] = [:]
    private var advertisementByID: [UUID: CapturedAdvertisement] = [:]
    private var pendingReads: Set<String> = []
    private var servicesAwaitingCharacteristics = 0
    /// What the emulator side subscribed to. CoreBluetooth forgets subscriptions when the
    /// link drops, so they are renewed after every reconnect.
    private var bridgeSubscriptions: Set<String> = []
    private var queuedWrites: [(CBCharacteristic, Data)] = []

    private var demo = DemoPeripheral()
    private var demoTicker: Task<Void, Never>?
    private var demoStartedByMirror = false

    struct CapturedAdvertisement {
        var localName: String?
        var manufacturerDataHex: String?
        var serviceUUIDs: [String]
        var serviceData: [String: String]
    }

    var isBluetoothReady: Bool { managerState == .poweredOn }
    var isScanning: Bool { state == .scanning }
    var isMirroring: Bool { bridgeProcess.isRunning }
    var isEmulatorConnected: Bool { isMirroring && bridgeProcess.isEmulatorClientConnected }

    var bluetoothProblem: String? {
        switch managerState {
        case .poweredOn, .unknown, .resetting: nil
        case .poweredOff: "Bluetooth is off. Turn it on in Control Center."
        case .unauthorized: "MacPhone may not use Bluetooth. Allow it in System Settings → Privacy & Security → Bluetooth."
        case .unsupported: "This Mac has no Bluetooth LE radio."
        @unknown default: "Bluetooth is in an unknown state."
        }
    }

    var mirrorSourceName: String? {
        switch state {
        case .demo: DemoPeripheral.name
        case .connected(let name), .reconnecting(let name): name
        default: nil
        }
    }

    func start() {
        guard central == nil else { return }
        // A nil queue delivers delegate calls on the main queue, which is this actor.
        central = CBCentralManager(delegate: self, queue: nil)
        server.onClientReady = { [weak self] in self?.replayToBridge() }
        server.onCommand = { [weak self] in self?.handle($0) }
    }

    // MARK: Scanning and connecting

    func startScan() {
        guard let central, central.state == .poweredOn else {
            append(.error, bluetoothProblem ?? "Bluetooth is not ready yet.")
            return
        }
        stopDevice()
        discovered.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        state = .scanning
        append(.info, "Scanning for BLE devices.")
    }

    func stopScan() {
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ id: UUID) {
        guard let central, let peripheral = peripheralCache[id] else { return }
        central.stopScan()
        target = peripheral
        let name = peripheral.name ?? id.uuidString
        state = .connecting(name)
        append(.info, "Connecting to \(name).")
        central.connect(peripheral, options: nil)
    }

    /// Back to idle from any state: a running scan, a connect that never completes
    /// (CoreBluetooth connects do not time out), a live link, a pending reconnect, the demo.
    func stopDevice() {
        central?.stopScan()
        if let peripheral = target {
            target = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        stopDemoTicker()
        services.removeAll()
        pendingReads.removeAll()
        queuedWrites.removeAll()
        if state.hasDevice { server.broadcast(["type": "state", "value": "disconnected"]) }
        state = .idle
    }

    // MARK: Demo device

    func startDemo() {
        stopDevice()
        demo = DemoPeripheral()
        services = demo.services
        state = .demo
        append(.info, "Demo device started.")
        replayToBridge()
    }

    private func stopDemoTicker() {
        demoTicker?.cancel()
        demoTicker = nil
    }

    // MARK: Mirror

    func startMirror() {
        if !state.hasDevice {
            startDemo()
            demoStartedByMirror = true
        }
        server.start()
        bridgeProcess.start(port: server.port, token: server.token)
        append(.info, "Mirroring \(mirrorSourceName ?? "the device") to the emulator.")
    }

    func stopMirror() {
        bridgeProcess.stop()
        server.stop()
        bridgeSubscriptions.removeAll()
        if demoStartedByMirror, state == .demo { stopDevice() }
        demoStartedByMirror = false
        append(.info, "Mirror stopped.")
    }

    // MARK: GATT operations

    func read(_ characteristic: BLECharacteristic) {
        if state == .demo {
            let value = demo.value(for: characteristic.uuid)
            report(value, for: characteristic.serviceUUID, characteristic.uuid, asRead: true)
            return
        }
        guard let cb = cbCharacteristic(characteristic.serviceUUID, characteristic.uuid) else { return }
        pendingReads.insert(characteristic.id)
        target?.readValue(for: cb)
        append(.outgoing, "Read \(characteristic.uuid.uuidString)")
    }

    func setNotify(_ enabled: Bool, for characteristic: BLECharacteristic) {
        if state == .demo {
            updateCharacteristic(characteristic.serviceUUID, characteristic.uuid, notifying: enabled)
            if characteristic.uuid == DemoPeripheral.batteryUUID { setDemoTicker(enabled) }
            return
        }
        guard let cb = cbCharacteristic(characteristic.serviceUUID, characteristic.uuid) else { return }
        target?.setNotifyValue(enabled, for: cb)
        append(.outgoing, "\(enabled ? "Subscribe" : "Unsubscribe") \(characteristic.uuid.uuidString)")
    }

    func write(hex: String, to characteristic: BLECharacteristic, withResponse: Bool) {
        guard let data = Data(hexString: hex) else {
            append(.error, "“\(hex)” is not valid hex.")
            return
        }
        if state == .demo {
            demo.write(data)
            updateCharacteristic(characteristic.serviceUUID, characteristic.uuid, value: data.hexString)
            append(.outgoing, "Write \(characteristic.uuid.uuidString) ← \(data.hexString)")
            return
        }
        guard let peripheral = target, let cb = cbCharacteristic(characteristic.serviceUUID, characteristic.uuid) else { return }
        if data.count > peripheral.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse) {
            append(.error, "\(data.count) bytes is more than this device accepts in one write.")
        }
        append(.outgoing, "Write \(characteristic.uuid.uuidString) ← \(data.hexString)")
        if withResponse {
            peripheral.writeValue(data, for: cb, type: .withResponse)
        } else if peripheral.canSendWriteWithoutResponse && queuedWrites.isEmpty {
            peripheral.writeValue(data, for: cb, type: .withoutResponse)
        } else {
            // Writes without response are dropped silently when the radio buffer is full.
            queuedWrites.append((cb, data))
        }
    }

    func clearLog() { log.removeAll() }

    // MARK: Bridge

    private func handle(_ command: BridgeCommand) {
        switch command {
        case .read(let service, let uuid):
            if let characteristic = find(uuid, in: service) { read(characteristic) }
        case .subscribe(let service, let uuid, let enabled):
            guard let characteristic = find(uuid, in: service) else { return }
            if enabled { bridgeSubscriptions.insert(characteristic.id) } else { bridgeSubscriptions.remove(characteristic.id) }
            if characteristic.isNotifying != enabled { setNotify(enabled, for: characteristic) }
        case .write(let service, let uuid, let hex, let withResponse):
            if let characteristic = find(uuid, in: service) { write(hex: hex, to: characteristic, withResponse: withResponse) }
        case .resetSession:
            resetSession()
        }
    }

    /// A new emulator client gets a fresh link to the real device, so session state in the
    /// device's own protocol does not leak from one app run to the next.
    private func resetSession() {
        guard case .connected(let name) = state, let central, let peripheral = target else { return }
        state = .reconnecting(name)
        append(.info, "Emulator client left; renewing the session with \(name).")
        central.cancelPeripheralConnection(peripheral)
    }

    private func replayToBridge() {
        guard state.hasDevice else { return }
        server.broadcast(["type": "state", "value": "connected"])
        if !services.isEmpty { server.broadcast(gattPayload()) }
    }

    private func find(_ uuid: String, in service: String?) -> BLECharacteristic? {
        // Both strings were validated by BridgeMessage.parse, so CBUUID(string:) cannot raise.
        let serviceID = service.map { CBUUID(string: $0) }
        let characteristicID = CBUUID(string: uuid)
        let match = services
            .filter { serviceID == nil || $0.uuid == serviceID }
            .flatMap(\.characteristics)
            .first { $0.uuid == characteristicID }
        if match == nil { append(.error, "The emulator asked for \(uuid), which this device does not have.") }
        return match
    }

    private func gattPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "type": "gatt",
            "services": services.map { service in
                [
                    "uuid": service.uuid.uuidString,
                    "characteristics": service.characteristics.map {
                        ["uuid": $0.uuid.uuidString, "service": service.uuid.uuidString, "properties": $0.properties] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
        if state == .demo {
            payload["advertisement"] = ["localName": DemoPeripheral.name, "serviceUUIDs": [DemoPeripheral.serviceUUID.uuidString]]
        } else if let id = target?.identifier, let ad = advertisementByID[id] {
            var advertisement: [String: Any] = ["serviceUUIDs": ad.serviceUUIDs]
            advertisement["localName"] = ad.localName
            advertisement["manufacturerData"] = ad.manufacturerDataHex
            if !ad.serviceData.isEmpty { advertisement["serviceData"] = ad.serviceData }
            payload["advertisement"] = advertisement
        }
        return payload
    }

    // MARK: Demo ticker

    private func setDemoTicker(_ running: Bool) {
        stopDemoTicker()
        guard running else { return }
        demoTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled, self.state == .demo else { return }
                let value = self.demo.tick()
                self.report(value, for: DemoPeripheral.serviceUUID, DemoPeripheral.batteryUUID, asRead: false)
            }
        }
    }

    // MARK: Helpers

    private func cbCharacteristic(_ service: CBUUID, _ characteristic: CBUUID) -> CBCharacteristic? {
        let match = target?.services?
            .first { $0.uuid == service }?
            .characteristics?
            .first { $0.uuid == characteristic }
        if match == nil { append(.error, "\(characteristic.uuidString) is not available right now.") }
        return match
    }

    private func report(_ value: Data, for service: CBUUID, _ characteristic: CBUUID, asRead: Bool) {
        let hex = value.hexString
        updateCharacteristic(service, characteristic, value: hex)
        append(.incoming, "\(asRead ? "Read" : "Notify") \(characteristic.uuidString) → \(hex.isEmpty ? "empty" : hex)")
        server.broadcast([
            "type": asRead ? "readResult" : "notification",
            "service": service.uuidString,
            "characteristic": characteristic.uuidString,
            "value": hex,
        ])
    }

    private func updateCharacteristic(_ service: CBUUID, _ characteristic: CBUUID, value: String? = nil, notifying: Bool? = nil) {
        guard let s = services.firstIndex(where: { $0.uuid == service }),
              let c = services[s].characteristics.firstIndex(where: { $0.uuid == characteristic })
        else { return }
        if let value { services[s].characteristics[c].lastValueHex = value }
        if let notifying { services[s].characteristics[c].isNotifying = notifying }
    }

    private func rebuildServices(from peripheral: CBPeripheral) {
        services = (peripheral.services ?? []).map { service in
            BLEService(uuid: service.uuid, characteristics: (service.characteristics ?? []).map {
                BLECharacteristic(uuid: $0.uuid, serviceUUID: service.uuid, properties: $0.properties.labels,
                                  isNotifying: $0.isNotifying, lastValueHex: $0.value?.hexString)
            })
        }
    }

    private func discoveryFinished(on peripheral: CBPeripheral) {
        rebuildServices(from: peripheral)
        server.broadcast(gattPayload())
        for characteristic in services.flatMap(\.characteristics) where bridgeSubscriptions.contains(characteristic.id) {
            setNotify(true, for: characteristic)
        }
    }

    private func append(_ direction: BLELogEntry.Direction, _ message: String) {
        log.append(BLELogEntry(timestamp: Date(), direction: direction, message: message))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEBridgeService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            managerState = central.state
            guard central.state != .poweredOn else { return }
            // Every connection is gone once the radio is off.
            target = nil
            services.removeAll()
            if state != .demo, state != .idle {
                state = .idle
                server.broadcast(["type": "state", "value": "disconnected"])
            }
            if let problem = bluetoothProblem { append(.error, problem) }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // The advertisement dictionary is not Sendable; pull out plain values first.
        let id = peripheral.identifier
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? ""
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        var serviceData: [String: String] = [:]
        for (uuid, value) in advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:] {
            serviceData[uuid.uuidString] = value.hexString
        }
        let manufacturerHex = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let rssi = RSSI.intValue

        MainActor.assumeIsolated {
            peripheralCache[id] = peripheral
            advertisementByID[id] = CapturedAdvertisement(
                localName: localName ?? (name.isEmpty ? nil : name),
                manufacturerDataHex: manufacturerHex,
                serviceUUIDs: serviceUUIDs,
                serviceData: serviceData
            )
            let entry = DiscoveredPeripheral(
                id: id,
                name: name,
                rssi: rssi,
                advertisedServices: serviceUUIDs,
                isConnectable: connectable
            )
            if let index = discovered.firstIndex(where: { $0.id == id }) {
                discovered[index] = entry
            } else {
                // Named devices first, then by name; RSSI jitter must not reorder the row
                // the user is about to click.
                let position = discovered.firstIndex {
                    let lhsNamed = !entry.name.isEmpty, rhsNamed = !$0.name.isEmpty
                    if lhsNamed != rhsNamed { return lhsNamed }
                    return entry.name.localizedCaseInsensitiveCompare($0.name) == .orderedAscending
                } ?? discovered.endIndex
                discovered.insert(entry, at: position)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === target else {
                // Stop was pressed while this connect was in flight.
                central.cancelPeripheralConnection(peripheral)
                return
            }
            let name = peripheral.name ?? peripheral.identifier.uuidString
            state = .connected(name)
            append(.info, "Connected to \(name). Discovering services.")
            server.broadcast(["type": "state", "value": "connected"])
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === target else { return }
            target = nil
            state = .idle
            append(.error, "Could not connect: \(error?.localizedDescription ?? "unknown error").")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === target else { return }
            services.removeAll()
            pendingReads.removeAll()
            queuedWrites.removeAll()
            server.broadcast(["type": "state", "value": "disconnected"])

            if case .reconnecting = state {
                central.connect(peripheral, options: nil)
                return
            }
            target = nil
            state = .idle
            append(.info, "Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ".")")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEBridgeService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === target else { return }
            if let error {
                append(.error, "Service discovery failed: \(error.localizedDescription)")
                return
            }
            let found = peripheral.services ?? []
            servicesAwaitingCharacteristics = found.count
            append(.info, "Found \(found.count) services.")
            if found.isEmpty { discoveryFinished(on: peripheral) }
            found.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === target else { return }
            if let error {
                append(.error, "Characteristics of \(service.uuid.uuidString) failed: \(error.localizedDescription)")
            }
            servicesAwaitingCharacteristics = max(0, servicesAwaitingCharacteristics - 1)
            // The bridge gets one complete tree, not a partial one per service.
            if servicesAwaitingCharacteristics == 0 {
                discoveryFinished(on: peripheral)
            } else {
                rebuildServices(from: peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === target, let service = characteristic.service else { return }
            let key = BLECharacteristic.key(service: service.uuid, characteristic: characteristic.uuid)
            // A notification must never answer a read the emulator is waiting on.
            let wasRead = pendingReads.remove(key) != nil
            if let error {
                append(.error, "\(wasRead ? "Read" : "Update") of \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
                return
            }
            report(characteristic.value ?? Data(), for: service.uuid, characteristic.uuid, asRead: wasRead)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { append(.error, "Write to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)") }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === target else { return }
            while peripheral.canSendWriteWithoutResponse, !queuedWrites.isEmpty {
                let (characteristic, data) = queuedWrites.removeFirst()
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === target, let service = characteristic.service else { return }
            if let error {
                append(.error, "Subscribing to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
            }
            updateCharacteristic(service.uuid, characteristic.uuid, notifying: characteristic.isNotifying)
        }
    }
}
