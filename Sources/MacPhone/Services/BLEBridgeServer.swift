import Foundation
import Observation
import Network
import Security

/// Localhost TCP server that hands the live GATT mirror to the netsim bridge.
///
/// One JSON object per line. Every client must open with
/// `{"cmd":"hello","token":"…"}` carrying the per-launch session token; anything else is
/// disconnected. Without that, any web page could POST GATT writes to 127.0.0.1 and reach
/// the real device while a mirror is running.
///
///   Server → client:
///     {"type":"state","value":"connected"|"disconnected"}
///     {"type":"gatt","services":[…],"advertisement":{…}}
///     {"type":"readResult"|"notification","service":"…","characteristic":"…","value":"<hex>"}
///   Client → server:
///     {"cmd":"read","service":"…","characteristic":"…"}
///     {"cmd":"subscribe","service":"…","characteristic":"…","enabled":true}
///     {"cmd":"write","service":"…","characteristic":"…","value":"<hex>","withResponse":true}
///     {"cmd":"resetSession"}
@Observable
@MainActor
final class BLEBridgeServer {
    private(set) var isRunning = false
    private(set) var port: UInt16 = 8765
    private(set) var clientCount = 0
    private(set) var lastError: String?

    /// Fresh for every app launch; handed to the bridge process and written to a 0600 file
    /// for a bridge started by hand.
    let token: String = BLEBridgeServer.makeToken()

    var onCommand: ((BridgeCommand) -> Void)?
    /// Called after a client authenticated, so the owner can replay state and GATT.
    var onClientReady: (() -> Void)?

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private let queue = DispatchQueue(label: "dev.johannesgrof.MacPhone.bridge")

    private struct Client {
        let connection: NWConnection
        var authenticated = false
    }

    static let maxClients = 2
    nonisolated static let maxLineLength = 256 * 1024

    func start(port: UInt16 = 8765) {
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid bridge port \(port)."
            return
        }
        self.port = port
        writeTokenFile()
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.lastError = nil
                    case .failed(let error):
                        self.lastError = "Bridge port \(port) is unavailable: \(error.localizedDescription)"
                        self.stop()
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        clients.values.forEach { $0.connection.cancel() }
        clients.removeAll()
        clientCount = 0
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func broadcast(_ object: [String: Any]) {
        let targets = clients.values.filter(\.authenticated).map(\.connection)
        guard !targets.isEmpty, var line = try? JSONSerialization.data(withJSONObject: object) else { return }
        line.append(0x0A)
        for connection in targets {
            connection.send(content: line, completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
            })
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard clients.count < Self.maxClients else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        clients[key] = Client(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(key) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, key: key, buffer: Data())

        // A client that never says hello is not a bridge.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if let client = self?.clients[key], !client.authenticated { client.connection.cancel() }
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        clients[key] = nil
        clientCount = clients.values.filter(\.authenticated).count
    }

    nonisolated private func receive(on connection: NWConnection, key: ObjectIdentifier, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var pending = buffer
            if let data { pending.append(data) }

            var lines: [Data] = []
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                lines.append(pending[start..<newline])
                start = pending.index(after: newline)
            }
            pending = Data(pending[start...])

            if !lines.isEmpty {
                Task { @MainActor in self?.handle(lines, from: key) }
            }
            if error != nil || isComplete || pending.count > Self.maxLineLength {
                connection.cancel()
                return
            }
            self?.receive(on: connection, key: key, buffer: pending)
        }
    }

    private func handle(_ lines: [Data], from key: ObjectIdentifier) {
        for line in lines {
            guard var client = clients[key] else { return }
            guard let message = BridgeMessage.parse(line) else {
                // HTTP request lines and other junk mean this is not our bridge.
                client.connection.cancel()
                return
            }
            if !client.authenticated {
                guard case .hello(let offered) = message, Self.constantTimeEqual(offered, token) else {
                    client.connection.cancel()
                    return
                }
                client.authenticated = true
                clients[key] = client
                clientCount = clients.values.filter(\.authenticated).count
                onClientReady?()
                continue
            }
            if case .command(let command) = message { onCommand?(command) }
        }
    }

    // MARK: Token

    nonisolated static var tokenFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPhone/bridge-token")
    }

    private func writeTokenFile() {
        let file = Self.tokenFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).hexString
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum BridgeCommand: Equatable, Sendable {
    case read(service: String?, characteristic: String)
    case subscribe(service: String?, characteristic: String, enabled: Bool)
    case write(service: String?, characteristic: String, hex: String, withResponse: Bool)
    case resetSession
}

enum BridgeMessage: Equatable, Sendable {
    case hello(String)
    case command(BridgeCommand)
    /// Well-formed JSON the server does not act on.
    case ignored

    static func parse(_ data: Data) -> BridgeMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = object["cmd"] as? String
        else { return nil }

        switch cmd {
        case "hello":
            return (object["token"] as? String).map(BridgeMessage.hello)
        case "resetSession":
            return .command(.resetSession)
        default:
            break
        }

        // UUIDs are validated here, before anything reaches CBUUID(string:), which raises an
        // uncatchable Objective-C exception on malformed input.
        guard let characteristic = (object["characteristic"] as? String).flatMap(BluetoothUUID.normalized) else {
            return .ignored
        }
        let rawService = object["service"] as? String
        let service = rawService.flatMap(BluetoothUUID.normalized)
        if let rawService, !rawService.isEmpty, service == nil { return .ignored }

        switch cmd {
        case "read":
            return .command(.read(service: service, characteristic: characteristic))
        case "subscribe":
            return .command(.subscribe(service: service, characteristic: characteristic, enabled: object["enabled"] as? Bool ?? true))
        case "write":
            guard let value = object["value"] as? String, Data(hexString: value) != nil else { return .ignored }
            return .command(.write(service: service, characteristic: characteristic, hex: value, withResponse: object["withResponse"] as? Bool ?? true))
        default:
            return .ignored
        }
    }
}

enum BluetoothUUID {
    /// Uppercased 16-bit, 32-bit or 128-bit UUID string, or nil if `CBUUID` would reject it.
    static func normalized(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let hex = CharacterSet(charactersIn: "0123456789ABCDEF")
        switch text.count {
        case 4, 8:
            return text.unicodeScalars.allSatisfy(hex.contains) ? text : nil
        case 36:
            return UUID(uuidString: text) != nil ? text : nil
        default:
            return nil
        }
    }
}
