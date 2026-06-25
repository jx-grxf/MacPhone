import Foundation
import Observation
@preconcurrency import CoreBluetooth

/// CoreBluetooth central-role bridge running on the Mac's internal radio — no external
/// USB controller required. It scans for, connects to and exchanges GATT data with a
/// real BLE peripheral (e.g. an e-scooter). The discovered GATT and live characteristic
/// traffic are exposed so a localhost bridge can mirror them to an emulator-side virtual
/// peripheral.
///
/// Apple does not allow raw internal-HCI passthrough to the Android emulator's virtual
/// controller, so bridging happens at the GATT/application layer. E-scooter protocols
/// (Xiaomi/Ninebot) encrypt at the application layer, not the BLE link layer, so a GATT
/// mirror is sufficient — no link-layer bonding is needed.
@Observable
@MainActor
final class BLEBridgeService: NSObject {
    // MARK: Observable state

    private(set) var connectionState: BLEConnectionState = .idle
    private(set) var managerState: CBManagerState = .unknown
    private(set) var discovered: [DiscoveredPeripheral] = []
    private(set) var services: [BLEService] = []
    private(set) var log: [BLELogEntry] = []
    private(set) var connectedPeripheralID: UUID?

    /// Optional service-UUID filters applied while scanning (empty = scan everything).
    var scanFilter: [CBUUID] = []

    /// Localhost server that mirrors the live GATT to the emulator side.
    let server = BLEBridgeServer()
    /// In-app supervisor for the Python netsim bridge process.
    let bridgeProcess = NetsimBridgeProcess()

    /// Demo mode publishes a synthetic battery device so the whole path (app → server →
    /// netsim bridge → emulator) can be exercised without any real BLE peripheral.
    private(set) var demoActive = false
    private var demoBattery: UInt8 = 87
    private var demoControlHex = "00"
    private var demoNotifyTask: Task<Void, Never>?
    private let demoServiceUUID = CBUUID(string: "180F")
    private let demoBatteryUUID = CBUUID(string: "2A19")
    private let demoControlUUID = CBUUID(string: "FFF1")
    private let demoPeripheralID = UUID()

    /// Optional M365 test device, exposed only when Test Devices is enabled in Settings.
    private(set) var scooterActive = false
    private(set) var scooterProfileID = VirtualScooterCatalog.default.id
    private var scooterEngine = VirtualScooter(profile: VirtualScooterCatalog.default)
    private let scooterPeripheralID = UUID()
    private let scooterServiceUUID = CBUUID(string: VirtualScooter.nusService)
    private let scooterTxUUID = CBUUID(string: VirtualScooter.nusTxNotify)
    private let scooterRxUUID = CBUUID(string: VirtualScooter.nusRxWrite)

    var isScanning: Bool {
        if case .scanning = connectionState { return true }
        return central?.isScanning ?? false
    }

    var isBluetoothReady: Bool { managerState == .poweredOn }

    var statusMessage: String {
        switch managerState {
        case .poweredOn: return connectionState.label
        case .poweredOff: return "Bluetooth is turned off."
        case .unauthorized: return "Bluetooth permission denied. Allow it in System Settings → Privacy."
        case .unsupported: return "This Mac reports no Bluetooth LE support."
        case .resetting: return "Bluetooth is resetting…"
        case .unknown: return "Initializing Bluetooth…"
        @unknown default: return "Bluetooth state unknown."
        }
    }

    // MARK: Private

    private var central: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var reconnectAfterDisconnect: CBPeripheral?
    /// Keep CBPeripheral references alive so connection callbacks fire.
    private var peripheralCache: [UUID: CBPeripheral] = [:]
    /// The advertisement seen for each peripheral, so the netsim mirror can re-broadcast the
    /// real device's name + manufacturer data for client-side device recognition.
    private var advertisementByID: [UUID: CapturedAdvertisement] = [:]

    struct CapturedAdvertisement {
        var localName: String?
        var manufacturerDataHex: String?
        var serviceUUIDs: [String]
        var serviceData: [String: String]   // service UUID → hex payload (e.g. Xiaomi FE95)
    }
    /// Characteristics ("service/char") with an in-flight explicit read, so the next value
    /// callback is reported as a read result rather than a spontaneous notification.
    private var pendingReads: Set<String> = []
    /// Services still awaiting characteristic discovery. The authoritative GATT snapshot is
    /// broadcast to the emulator only once this reaches zero, so the bridge sees one complete
    /// tree instead of a partial one per service.
    private var servicesAwaitingCharacteristics = 0

    // MARK: Lifecycle

    func start() {
        guard central == nil else { return }
        // nil queue → delegate callbacks arrive on the main queue, matching @MainActor.
        central = CBCentralManager(delegate: self, queue: nil)
        wireServer()
    }

    func startBridgeServer(port: UInt16 = 8765) {
        server.start(port: port)
        append(.info, "Bridge server listening on 127.0.0.1:\(port).")
    }

    func stopBridgeServer() {
        server.stop()
        append(.info, "Bridge server stopped.")
    }

    /// Start the Python netsim bridge from inside the app, attached to our own server.
    func startNetsimBridge() {
        if !server.isRunning { startBridgeServer() }
        bridgeProcess.start(port: server.port)
        append(.info, "Starting netsim bridge process…")
    }

    func stopNetsimBridge() {
        bridgeProcess.stop()
        append(.info, "Stopped netsim bridge process.")
    }

    /// One-click "mirror to emulator": guarantees there is always something to mirror
    /// (falls back to the demo device), brings the server up, and launches the bridge — so
    /// the user never has to sequence server / device / bridge by hand.
    func startEmulatorMirror() {
        if connectedPeripheralID == nil && !demoActive {
            startDemo()
        }
        if !server.isRunning { startBridgeServer() }
        bridgeProcess.start(port: server.port)
        append(.info, "Mirroring to emulator…")
    }

    /// Tear the mirror down: stop the bridge process, the demo device, and the server.
    func stopEmulatorMirror() {
        bridgeProcess.stop()
        if demoActive { stopDemo() }
        server.stop()
        append(.info, "Stopped mirroring to emulator.")
    }

    /// True while the full mirror path is live end-to-end (bridge attached to our server).
    var isMirroring: Bool { bridgeProcess.isRunning }

    /// Always return to a clean scanning state: stop the mirror, drop the demo, and
    /// disconnect any real peripheral — so the nearby-devices list is reachable again.
    func leaveCurrentDevice() {
        if isMirroring { stopEmulatorMirror() }
        if demoActive { stopDemo() }
        if scooterActive { stopVirtualScooter() }
        if connectedPeripheral != nil { disconnect() }
        // Land back on a live scan rather than an empty list, so the user is never stranded
        // with no way to pick another device (matches the "Disconnect & Scan" affordance).
        if isBluetoothReady { startScan() }
    }

    /// What is being mirrored, for the UI subtitle.
    var mirrorSourceLabel: String {
        if scooterActive { return "Virtual M365 scooter" }
        if demoActive { return "Demo battery device" }
        if case .connected(let name) = connectionState { return name }
        return "no device — connect one or use Demo"
    }

    // MARK: Demo device

    func startDemo() {
        guard !demoActive else { return }
        if connectedPeripheralID != nil { disconnect() }
        demoActive = true
        demoBattery = 87
        let battery = BLECharacteristic(
            uuid: demoBatteryUUID, serviceUUID: demoServiceUUID,
            properties: ["read", "notify"], isNotifying: false,
            lastValueHex: String(format: "%02x", demoBattery)
        )
        let control = BLECharacteristic(
            uuid: demoControlUUID, serviceUUID: demoServiceUUID,
            properties: ["read", "write"], isNotifying: false, lastValueHex: demoControlHex
        )
        services = [BLEService(uuid: demoServiceUUID, characteristics: [battery, control])]
        connectedPeripheralID = demoPeripheralID
        connectionState = .connected("Demo Device")
        append(.info, "Demo device active — synthetic battery service mirrored to the emulator.")
        if server.isRunning {
            server.broadcast(["type": "state", "value": "connected"])
            server.broadcast(gattPayload())
        }
    }

    func stopDemo() {
        guard demoActive else { return }
        demoActive = false
        demoNotifyTask?.cancel()
        demoNotifyTask = nil
        services.removeAll()
        connectedPeripheralID = nil
        connectionState = .disconnected
        append(.info, "Demo device stopped.")
        if server.isRunning { server.broadcast(["type": "state", "value": "disconnected"]) }
    }

    private func demoRead(_ characteristic: BLECharacteristic) {
        let hex = characteristic.uuid == demoBatteryUUID ? String(format: "%02x", demoBattery) : demoControlHex
        updateValue(serviceUUID: characteristic.serviceUUID, characteristicUUID: characteristic.uuid, hex: hex, isNotifying: characteristic.isNotifying)
        append(.incoming, "DEMO READ← \(characteristic.uuid.uuidString) → \(hex)")
        if server.isRunning {
            server.broadcast([
                "type": "readResult",
                "service": characteristic.serviceUUID.uuidString,
                "characteristic": characteristic.uuid.uuidString,
                "value": hex
            ])
        }
    }

    private func demoSetNotify(_ enabled: Bool, for characteristic: BLECharacteristic) {
        updateValue(serviceUUID: characteristic.serviceUUID, characteristicUUID: characteristic.uuid, hex: nil, isNotifying: enabled)
        append(.info, "DEMO notifications \(enabled ? "enabled" : "disabled") for \(characteristic.uuid.uuidString).")
        guard characteristic.uuid == demoBatteryUUID else { return }
        demoNotifyTask?.cancel()
        guard enabled else { demoNotifyTask = nil; return }
        demoNotifyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.demoActive == true {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled, self.demoActive else { break }
                self.demoBattery = self.demoBattery > 5 ? self.demoBattery - 1 : 100
                let hex = String(format: "%02x", self.demoBattery)
                self.updateValue(serviceUUID: self.demoServiceUUID, characteristicUUID: self.demoBatteryUUID, hex: hex, isNotifying: true)
                self.append(.incoming, "DEMO NOTIFY 2A19 → \(hex)")
                if self.server.isRunning {
                    self.server.broadcast([
                        "type": "notification",
                        "service": self.demoServiceUUID.uuidString,
                        "characteristic": self.demoBatteryUUID.uuidString,
                        "value": hex
                    ])
                }
            }
        }
    }

    private func demoWrite(hex: String, to characteristic: BLECharacteristic) {
        demoControlHex = hex
        updateValue(serviceUUID: characteristic.serviceUUID, characteristicUUID: characteristic.uuid, hex: hex, isNotifying: characteristic.isNotifying)
        append(.outgoing, "DEMO WRITE \(characteristic.uuid.uuidString) ← \(hex)")
    }

    // MARK: Virtual scooter

    func startVirtualScooter(profile: VirtualScooter.Profile = VirtualScooterCatalog.default) {
        guard !scooterActive, connectedPeripheralID == nil else { return }
        stopScan()
        if demoActive { stopDemo() }
        scooterActive = true
        scooterProfileID = profile.id
        scooterEngine = VirtualScooter(profile: profile)

        let transmit = BLECharacteristic(
            uuid: scooterTxUUID,
            serviceUUID: scooterServiceUUID,
            properties: ["notify"],
            isNotifying: false,
            lastValueHex: nil
        )
        let receive = BLECharacteristic(
            uuid: scooterRxUUID,
            serviceUUID: scooterServiceUUID,
            properties: ["write", "writeNR"],
            isNotifying: false,
            lastValueHex: nil
        )
        services = [
            BLEService(
                uuid: scooterServiceUUID,
                characteristics: [transmit, receive]
            )
        ]
        connectedPeripheralID = scooterPeripheralID
        connectionState = .connected(scooterEngine.advertisedName)
        advertisementByID[scooterPeripheralID] = CapturedAdvertisement(
            localName: scooterEngine.advertisedName,
            manufacturerDataHex: scooterEngine.manufacturerDataHex,
            serviceUUIDs: [VirtualScooter.nusService],
            serviceData: [:]
        )
        append(
            .info,
            "Virtual scooter active — \(profile.displayName). Mirror it to the emulator, then connect in E-Tune."
        )
        if server.isRunning {
            server.broadcast(["type": "state", "value": "connected"])
            server.broadcast(gattPayload())
        }
    }

    func stopVirtualScooter() {
        guard scooterActive else { return }
        scooterActive = false
        advertisementByID[scooterPeripheralID] = nil
        services.removeAll()
        connectedPeripheralID = nil
        connectionState = .disconnected
        append(.info, "Virtual scooter stopped.")
        if server.isRunning {
            server.broadcast(["type": "state", "value": "disconnected"])
        }
    }

    private func scooterSetNotify(
        _ enabled: Bool,
        for characteristic: BLECharacteristic
    ) {
        updateValue(
            serviceUUID: characteristic.serviceUUID,
            characteristicUUID: characteristic.uuid,
            hex: nil,
            isNotifying: enabled
        )
        append(
            .info,
            "SCOOTER notifications \(enabled ? "enabled" : "disabled") for \(characteristic.uuid.uuidString)."
        )
    }

    private func scooterWrite(hex: String, to characteristic: BLECharacteristic) {
        guard let data = Data(hexString: hex) else {
            append(.error, "Invalid hex payload.")
            return
        }
        append(.outgoing, "SCOOTER WRITE \(characteristic.uuid.uuidString) ← \(hex)")
        for reply in scooterEngine.reply(to: [UInt8](data)) {
            let replyHex = Data(reply).hexString
            updateValue(
                serviceUUID: scooterServiceUUID,
                characteristicUUID: scooterTxUUID,
                hex: replyHex,
                isNotifying: true
            )
            append(.incoming, "SCOOTER NOTIFY → \(replyHex)")
            if server.isRunning {
                server.broadcast([
                    "type": "notification",
                    "service": scooterServiceUUID.uuidString,
                    "characteristic": scooterTxUUID.uuidString,
                    "value": replyHex
                ])
            }
        }
    }

    /// Route commands coming from the emulator side into GATT operations.
    private func wireServer() {
        // Replay the current connection state + GATT to any client that joins late.
        server.onClientConnected = { [weak self] in
            guard let self, self.connectedPeripheralID != nil else { return }
            self.server.broadcast(["type": "state", "value": "connected"])
            if !self.services.isEmpty {
                self.server.broadcast(self.gattPayload())
            }
        }

        server.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .read(let service, let uuid):
                if let characteristic = self.findCharacteristic(uuid, service: service) {
                    self.readValue(for: characteristic)
                }
            case .subscribe(let service, let uuid, let enabled):
                if let characteristic = self.findCharacteristic(uuid, service: service) {
                    self.setNotify(enabled, for: characteristic)
                }
            case .write(let service, let uuid, let hex, let withResponse):
                if let characteristic = self.findCharacteristic(uuid, service: service) {
                    self.write(hex: hex, to: characteristic, withResponse: withResponse)
                }
            case .resetSession:
                self.resetRealDeviceSession()
            }
        }
    }

    /// Resolve a characteristic by UUID, optionally constrained to a service so that the
    /// same characteristic UUID appearing under two services routes unambiguously.
    private func findCharacteristic(_ uuidString: String, service serviceString: String?) -> BLECharacteristic? {
        let target = CBUUID(string: uuidString)
        let serviceTarget = serviceString.map { CBUUID(string: $0) }
        for service in services where serviceTarget == nil || service.uuid == serviceTarget {
            if let match = service.characteristics.first(where: { $0.uuid == target }) {
                return match
            }
        }
        append(.error, "Bridge: characteristic \(uuidString) not found\(serviceString.map { " in service \($0)" } ?? "").")
        return nil
    }

    private func gattPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "type": "gatt",
            "services": services.map { service in
                [
                    "uuid": service.uuid.uuidString,
                    "characteristics": service.characteristics.map { characteristic in
                        [
                            "uuid": characteristic.uuid.uuidString,
                            "service": service.uuid.uuidString,
                            "properties": characteristic.properties
                        ] as [String: Any]
                    }
                ] as [String: Any]
            }
        ]
        // Forward the real device's advertisement so the netsim mirror can re-broadcast it.
        if let id = connectedPeripheralID, let ad = advertisementByID[id] {
            var advertisement: [String: Any] = ["serviceUUIDs": ad.serviceUUIDs]
            if let localName = ad.localName { advertisement["localName"] = localName }
            if let mfg = ad.manufacturerDataHex { advertisement["manufacturerData"] = mfg }
            if !ad.serviceData.isEmpty { advertisement["serviceData"] = ad.serviceData }
            payload["advertisement"] = advertisement
        }
        return payload
    }

    func startScan() {
        guard let central, central.state == .poweredOn else {
            append(.error, "Cannot scan: \(statusMessage)")
            return
        }
        discovered.removeAll()
        central.scanForPeripherals(
            withServices: scanFilter.isEmpty ? nil : scanFilter,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        connectionState = .scanning
        append(.info, scanFilter.isEmpty ? "Scanning for all peripherals…" : "Scanning for \(scanFilter.map(\.uuidString).joined(separator: ", "))…")
    }

    func stopScan() {
        central?.stopScan()
        if case .scanning = connectionState { connectionState = .idle }
    }

    func connect(_ id: UUID) {
        guard let central, let peripheral = peripheralCache[id] else {
            append(.error, "Unknown peripheral \(id).")
            return
        }
        stopScan()
        let name = peripheral.name ?? id.uuidString
        connectionState = .connecting(name)
        append(.info, "Connecting to \(name)…")
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let central, let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    /// A new virtual Android GATT client gets a fresh real BLE session so
    /// application-layer session state cannot leak across clients.
    private func resetRealDeviceSession() {
        guard !demoActive, !scooterActive,
              let central, let peripheral = connectedPeripheral,
              reconnectAfterDisconnect == nil else { return }
        reconnectAfterDisconnect = peripheral
        append(.info, "Android client disconnected; resetting real BLE session…")
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: GATT operations

    func readValue(for characteristic: BLECharacteristic) {
        if scooterActive { return }
        if demoActive { demoRead(characteristic); return }
        guard let cb = cbCharacteristic(for: characteristic) else { return }
        pendingReads.insert(characteristic.id)
        connectedPeripheral?.readValue(for: cb)
        append(.outgoing, "READ \(characteristic.uuid.uuidString)")
    }

    func setNotify(_ enabled: Bool, for characteristic: BLECharacteristic) {
        if scooterActive {
            scooterSetNotify(enabled, for: characteristic)
            return
        }
        if demoActive { demoSetNotify(enabled, for: characteristic); return }
        guard let cb = cbCharacteristic(for: characteristic) else { return }
        connectedPeripheral?.setNotifyValue(enabled, for: cb)
        append(.outgoing, "\(enabled ? "SUBSCRIBE" : "UNSUBSCRIBE") \(characteristic.uuid.uuidString)")
    }

    func write(hex: String, to characteristic: BLECharacteristic, withResponse: Bool) {
        guard let data = Data(hexString: hex) else {
            append(.error, "Invalid hex payload.")
            return
        }
        if scooterActive {
            scooterWrite(hex: data.hexString, to: characteristic)
            return
        }
        if demoActive { demoWrite(hex: data.hexString, to: characteristic); return }
        write(data, to: characteristic, withResponse: withResponse)
    }

    func write(_ data: Data, to characteristic: BLECharacteristic, withResponse: Bool) {
        guard let cb = cbCharacteristic(for: characteristic) else { return }
        connectedPeripheral?.writeValue(data, for: cb, type: withResponse ? .withResponse : .withoutResponse)
        append(.outgoing, "WRITE \(characteristic.uuid.uuidString) ← \(data.hexString)")
    }

    func clearLog() { log.removeAll() }

    // MARK: Helpers

    private func cbCharacteristic(for characteristic: BLECharacteristic) -> CBCharacteristic? {
        guard let peripheral = connectedPeripheral else { return nil }
        for service in peripheral.services ?? [] where service.uuid == characteristic.serviceUUID {
            for cb in service.characteristics ?? [] where cb.uuid == characteristic.uuid {
                return cb
            }
        }
        append(.error, "Characteristic \(characteristic.uuid.uuidString) not found on peripheral.")
        return nil
    }

    private func append(_ direction: BLELogEntry.Direction, _ message: String) {
        log.append(BLELogEntry(timestamp: Date(), direction: direction, message: message))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    /// Rebuild the whole service tree — only after structural discovery, never on every
    /// notification. Stable model ids keep SwiftUI identities intact across rebuilds.
    /// The GATT is broadcast to the emulator only when `broadcast` is true (i.e. once the
    /// whole tree is known), so the bridge never consumes a partial snapshot.
    fileprivate func rebuildGATT(from peripheral: CBPeripheral, broadcast: Bool) {
        var built: [BLEService] = []
        for service in peripheral.services ?? [] {
            let characteristics = (service.characteristics ?? []).map { cb in
                BLECharacteristic(
                    uuid: cb.uuid,
                    serviceUUID: service.uuid,
                    properties: cb.properties.labels,
                    isNotifying: cb.isNotifying,
                    lastValueHex: cb.value?.hexString
                )
            }
            built.append(BLEService(uuid: service.uuid, characteristics: characteristics))
        }
        services = built
        if broadcast, server.isRunning {
            server.broadcast(gattPayload())
        }
    }

    /// Update a single characteristic's value/notify flag in place — cheap, and does not
    /// re-broadcast the whole GATT or churn SwiftUI identities.
    fileprivate func updateValue(serviceUUID: CBUUID?, characteristicUUID: CBUUID, hex: String?, isNotifying: Bool) {
        guard let serviceUUID,
              let serviceIndex = services.firstIndex(where: { $0.uuid == serviceUUID }),
              let charIndex = services[serviceIndex].characteristics.firstIndex(where: { $0.uuid == characteristicUUID })
        else { return }
        if let hex { services[serviceIndex].characteristics[charIndex].lastValueHex = hex }
        services[serviceIndex].characteristics[charIndex].isNotifying = isNotifying
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEBridgeService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.managerState = state
            self.append(.info, "Bluetooth state: \(self.statusMessage)")
            if state != .poweredOn, case .scanning = self.connectionState {
                self.connectionState = .idle
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let rssi = RSSI.intValue
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let manufacturerHex = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString
        var serviceData: [String: String] = [:]
        if let raw = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, value) in raw { serviceData[uuid.uuidString] = value.hexString }
        }

        Task { @MainActor in
            self.peripheralCache[id] = peripheral
            self.advertisementByID[id] = CapturedAdvertisement(
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
                isConnectable: connectable,
                lastSeen: Date()
            )
            if let index = self.discovered.firstIndex(where: { $0.id == id }) {
                // Update in place — never reorder a row the user might be about to click.
                self.discovered[index] = entry
            } else {
                self.discovered.append(entry)
                // Stable order independent of RSSI: named devices first (alphabetical),
                // then unnamed by id. RSSI jitter no longer shuffles the list.
                self.discovered.sort { lhs, rhs in
                    let lNamed = !lhs.name.isEmpty, rNamed = !rhs.name.isEmpty
                    if lNamed != rNamed { return lNamed }
                    if lhs.name != rhs.name {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectedPeripheral = peripheral
            self.connectedPeripheralID = peripheral.identifier
            self.connectionState = .connected(peripheral.name ?? peripheral.identifier.uuidString)
            self.append(.info, "Connected. Discovering services…")
            if self.server.isRunning {
                self.server.broadcast(["type": "state", "value": "connected"])
            }
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let message = error?.localizedDescription ?? "unknown error"
        Task { @MainActor in
            self.connectionState = .disconnected
            self.append(.error, "Failed to connect: \(message)")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let message = error?.localizedDescription
        Task { @MainActor in
            let shouldReconnect = self.reconnectAfterDisconnect?.identifier == peripheral.identifier
            self.connectedPeripheral = nil
            self.connectedPeripheralID = nil
            self.services.removeAll()
            self.pendingReads.removeAll()
            self.connectionState = .disconnected
            self.append(.info, "Disconnected\(message.map { ": \($0)" } ?? ".")")
            if self.server.isRunning {
                self.server.broadcast(["type": "state", "value": "disconnected"])
            }
            if shouldReconnect {
                self.reconnectAfterDisconnect = nil
                self.connectionState = .connecting(peripheral.name ?? peripheral.identifier.uuidString)
                self.append(.info, "Reconnecting real BLE session…")
                self.central?.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEBridgeService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.append(.error, "Service discovery failed: \(error.localizedDescription)")
                return
            }
            let serviceList = peripheral.services ?? []
            self.servicesAwaitingCharacteristics = serviceList.count
            for service in serviceList {
                peripheral.discoverCharacteristics(nil, for: service)
            }
            self.append(.info, "Found \(serviceList.count) services.")
            if serviceList.isEmpty, self.server.isRunning {
                self.server.broadcast(self.gattPayload())
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let serviceUUID = service.uuid.uuidString
        let count = service.characteristics?.count ?? 0
        Task { @MainActor in
            if let error {
                self.append(.error, "Characteristic discovery failed for \(serviceUUID): \(error.localizedDescription)")
            } else {
                self.append(.info, "Service \(serviceUUID): \(count) characteristics.")
            }
            if self.servicesAwaitingCharacteristics > 0 {
                self.servicesAwaitingCharacteristics -= 1
            }
            // Update the UI tree on every service, but only push the snapshot to the
            // emulator once every service has reported its characteristics.
            let complete = self.servicesAwaitingCharacteristics == 0
            self.rebuildGATT(from: peripheral, broadcast: complete)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid.uuidString
        let serviceUUID = characteristic.service?.uuid
        let serviceUUIDString = serviceUUID?.uuidString
        let charUUID = characteristic.uuid
        let hex = characteristic.value?.hexString
        let isNotifying = characteristic.isNotifying
        let errorMessage = error?.localizedDescription
        Task { @MainActor in
            // A value can arrive either as the answer to an explicit read or as a
            // spontaneous notification. Distinguish them so the emulator side never
            // mistakes a stray notification for the read it is waiting on.
            let key = serviceUUIDString.map { "\($0)/\(uuid)" } ?? uuid
            let wasRead = self.pendingReads.remove(key) != nil
            if let errorMessage {
                self.append(.error, "\(wasRead ? "Read" : "Value") failed for \(uuid): \(errorMessage)")
            } else {
                self.append(.incoming, "\(wasRead ? "READ←" : "NOTIFY") \(uuid) → \(hex ?? "<empty>")")
                if self.server.isRunning {
                    self.server.broadcast([
                        "type": wasRead ? "readResult" : "notification",
                        "service": serviceUUIDString ?? "",
                        "characteristic": uuid,
                        "value": hex ?? ""
                    ])
                }
            }
            self.updateValue(serviceUUID: serviceUUID, characteristicUUID: charUUID, hex: hex, isNotifying: isNotifying)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid.uuidString
        let errorMessage = error?.localizedDescription
        Task { @MainActor in
            if let errorMessage {
                self.append(.error, "Write failed for \(uuid): \(errorMessage)")
            } else {
                self.append(.info, "Write acknowledged for \(uuid).")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid.uuidString
        let serviceUUID = characteristic.service?.uuid
        let charUUID = characteristic.uuid
        let isNotifying = characteristic.isNotifying
        let errorMessage = error?.localizedDescription
        Task { @MainActor in
            if let errorMessage {
                self.append(.error, "Notify toggle failed for \(uuid): \(errorMessage)")
            } else {
                self.append(.info, "Notifications \(isNotifying ? "enabled" : "disabled") for \(uuid).")
            }
            self.updateValue(serviceUUID: serviceUUID, characteristicUUID: charUUID, hex: nil, isNotifying: isNotifying)
        }
    }
}
