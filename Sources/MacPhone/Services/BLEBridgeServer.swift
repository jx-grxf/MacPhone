import Foundation
import Observation
import Network

/// Localhost TCP server that exposes the live GATT mirror to the emulator side.
///
/// The Mac connects to the real peripheral over CoreBluetooth (internal radio, central
/// role). This server re-publishes that peripheral's services, characteristics and live
/// notification traffic as newline-delimited JSON on 127.0.0.1, and accepts read/write/
/// subscribe commands back. A Bumble virtual peripheral on the Android emulator's netsim
/// controller consumes this feed and presents the same GATT to the app under test — so
/// no external USB Bluetooth controller is required.
///
/// Protocol (one JSON object per line, UTF-8):
///   Server → client events:
///     {"type":"state","value":"connected"}
///     {"type":"gatt","services":[{"uuid":"…","characteristics":[{"uuid":"…","service":"…","properties":["read","notify"]}]}]}
///     {"type":"readResult","service":"…","characteristic":"…","value":"<hex>"}
///     {"type":"notification","service":"…","characteristic":"…","value":"<hex>"}
///   Client → server commands (service is optional but disambiguates duplicate char UUIDs):
///     {"cmd":"read","service":"…","characteristic":"…"}
///     {"cmd":"subscribe","service":"…","characteristic":"…","enabled":true}
///     {"cmd":"write","service":"…","characteristic":"…","value":"<hex>","withResponse":true}
@Observable
@MainActor
final class BLEBridgeServer {
    private(set) var isRunning = false
    private(set) var port: UInt16 = 8765
    private(set) var clientCount = 0
    private(set) var lastError: String?

    /// Invoked when a client sends a command. Wired to the BLE service by the owner.
    var onCommand: ((BridgeCommand) -> Void)?
    /// Invoked when a new client connects, so the owner can replay the current
    /// connection state + GATT snapshot (a client that joins after a device is already
    /// connected would otherwise never receive the GATT).
    var onClientConnected: (() -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "dev.johannesgrof.MacPhone.bridge")

    enum BridgeCommand {
        case read(service: String?, characteristic: String)
        case subscribe(service: String?, characteristic: String, enabled: Bool)
        case write(service: String?, characteristic: String, hex: String, withResponse: Bool)
        case resetSession
    }

    func start(port: UInt16 = 8765) {
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid bridge port: \(port)."
            return
        }
        self.port = port
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: endpointPort
            )
            let listener = try NWListener(using: params)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                        self?.stop()
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        clientCount = 0
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// Broadcast a JSON-encodable event to every connected client.
    func broadcast(_ object: [String: Any]) {
        guard !connections.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A) // newline delimiter
        for connection in connections.values {
            connection.send(content: line, completion: .contentProcessed { _ in })
        }
    }

    // MARK: Connections

    nonisolated private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        Task { @MainActor in
            self.connections[key] = connection
            self.clientCount = self.connections.count
            self.onClientConnected?()
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.connections[key] = nil
                    self?.clientCount = self?.connections.count ?? 0
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Upper bound on a single newline-delimited command. A well-behaved bridge client sends
    /// short JSON lines; anything larger is a malformed/runaway client and is dropped rather
    /// than buffered without limit.
    nonisolated private static let maxLineLength = 256 * 1024

    nonisolated private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var working = buffer
            if let data, !data.isEmpty { working.append(data) }

            // Split on newline; dispatch each complete line as a command.
            while let newlineIndex = working.firstIndex(of: 0x0A) {
                let lineData = working[working.startIndex..<newlineIndex]
                if let command = Self.parseCommand(Data(lineData)) {
                    Task { @MainActor in self?.onCommand?(command) }
                }
                working = Data(working[working.index(after: newlineIndex)...])
            }

            if error != nil || isComplete {
                connection.cancel()
                return
            }
            // No newline yet but the pending buffer is already oversized: the peer is not
            // speaking the line protocol. Close it instead of growing memory unbounded.
            if working.count > Self.maxLineLength {
                connection.cancel()
                return
            }
            self?.receive(on: connection, buffer: working)
        }
    }

    nonisolated private static func parseCommand(_ data: Data) -> BridgeCommand? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = object["cmd"] as? String else { return nil }

        if cmd == "resetSession" {
            return .resetSession
        }

        guard let characteristic = object["characteristic"] as? String else { return nil }
        let service = object["service"] as? String

        switch cmd {
        case "read":
            return .read(service: service, characteristic: characteristic)
        case "subscribe":
            return .subscribe(service: service, characteristic: characteristic, enabled: object["enabled"] as? Bool ?? true)
        case "write":
            guard let value = object["value"] as? String else { return nil }
            return .write(service: service, characteristic: characteristic, hex: value, withResponse: object["withResponse"] as? Bool ?? true)
        default:
            return nil
        }
    }
}
