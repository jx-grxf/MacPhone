import Foundation
import Testing
@testable import MacPhone

struct BridgeMessageTests {
    @Test func helloCarriesToken() {
        #expect(BridgeMessage.parse(Data(#"{"cmd":"hello","token":"abc"}"#.utf8)) == .hello("abc"))
    }

    @Test func writeIsParsed() {
        let line = #"{"cmd":"write","service":"180f","characteristic":"2a19","value":"0a0b","withResponse":false}"#
        #expect(BridgeMessage.parse(Data(line.utf8)) == .command(.write(service: "180F", characteristic: "2A19", hex: "0a0b", withResponse: false)))
    }

    @Test(arguments: ["not-a-uuid", "12345", "ZZZZ", ""])
    func malformedUUIDIsIgnored(_ uuid: String) {
        let line = #"{"cmd":"read","characteristic":"\#(uuid)"}"#
        #expect(BridgeMessage.parse(Data(line.utf8)) == .ignored)
    }

    @Test func malformedServiceIsIgnored() {
        let line = #"{"cmd":"read","service":"nope","characteristic":"2A19"}"#
        #expect(BridgeMessage.parse(Data(line.utf8)) == .ignored)
    }

    @Test func invalidHexIsIgnored() {
        let line = #"{"cmd":"write","characteristic":"2A19","value":"xyz"}"#
        #expect(BridgeMessage.parse(Data(line.utf8)) == .ignored)
    }

    @Test(arguments: ["POST / HTTP/1.1", "Host: 127.0.0.1:8765", "{}", "[1,2]"])
    func nonCommandsAreRejected(_ line: String) {
        #expect(BridgeMessage.parse(Data(line.utf8)) == nil)
    }

    @Test func fullUUIDIsAccepted() {
        #expect(BluetoothUUID.normalized("6e400001-b5a3-f393-e0a9-e50e24dcca9e") == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    }
}

struct HexTests {
    @Test func roundTrip() {
        let data = Data([0x00, 0x0f, 0xa0, 0xff])
        #expect(data.hexString == "000fa0ff")
        #expect(Data(hexString: "000FA0ff") == data)
        #expect(Data(hexString: "00 0f a0 ff") == data)
    }

    @Test func rejectsBadInput() {
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
    }
}

struct SimulatorParsingTests {
    @Test(arguments: [
        ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "iOS 27.0"),
        ("com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "watchOS 27.0"),
        ("com.apple.CoreSimulator.SimRuntime.xrOS-3-1", "visionOS 3.1"),
        ("com.apple.CoreSimulator.SimRuntime.tvOS-26-4", "tvOS 26.4"),
    ])
    func runtimeNames(_ identifier: String, _ expected: String) {
        #expect(SimulatorRuntimeName.readable(identifier) == expected)
    }

    @Test func devicesAreParsedAndGrouped() {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.watchOS-27-0":[
            {"udid":"A","name":"Apple Watch Ultra 4 (49mm)","state":"Shutdown","isAvailable":true,
             "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-4-49mm"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
            {"udid":"B","name":"iPhone 18 Pro","state":"Booted","isAvailable":true,
             "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"},
            {"udid":"C","name":"Gone","state":"Shutdown","isAvailable":false,
             "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Air"}]
        }}
        """
        let devices = SimulatorService.parseDevices(json).sorted { $0.identifier < $1.identifier }
        #expect(devices.count == 2)
        #expect(devices[0].family == .watch)
        #expect(devices[0].osVersion == "watchOS 27.0")
        #expect(devices[1].family == .iPhone)
        #expect(devices[1].state == .booted)
    }

    @Test func catalogFiltersDeviceTypesByRuntime() throws {
        let json = """
        {"runtimes":[{"identifier":"rt.ios","name":"iOS 27.0","platform":"iOS","version":"27.0","isAvailable":true,
                      "supportedDeviceTypes":[{"identifier":"dt.iphone"}]}],
         "devicetypes":[{"identifier":"dt.iphone","name":"iPhone 18"},{"identifier":"dt.watch","name":"Apple Watch"}]}
        """
        let catalog = try SimulatorService.parseCatalog(json)
        #expect(catalog.deviceTypes(for: "rt.ios").map(\.id) == ["dt.iphone"])
    }
}

struct AndroidParsingTests {
    @Test func adbDevices() {
        let output = """
        * daemon started successfully
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a
        R58M123ABC             unauthorized usb:1-1
        emulator-5556          offline

        """
        let devices = AndroidService.parseADBDevices(output)
        #expect(devices.map(\.serial) == ["emulator-5554", "R58M123ABC", "emulator-5556"])
        #expect(devices[0].model == "sdk gphone64 arm64")
        #expect(devices[2].state == "offline")
    }

    @Test func avdListSkipsEmulatorNoise() {
        let output = "INFO    | Storing crashdata in: /tmp\nPixel_9\nMy_Tablet\n"
        #expect(AndroidService.parseAVDList(output) == ["Pixel_9", "My_Tablet"])
    }

    @Test func configUpdateReplacesAndAppends() {
        let input = "hw.gpu.mode=auto\nhw.lcd.width=1080\n"
        let output = AndroidAVDPerformance.updated(input, values: ["hw.gpu.mode": "host", "hw.ramSize": "2048"])
        #expect(output == "hw.gpu.mode=host\nhw.lcd.width=1080\nhw.ramSize=2048\n")
    }

    @Test func systemImagePackage() {
        let request = AndroidProvisioner.Request(name: "My Phone!", platform: "37.0", tag: "google_apis", device: "pixel_9")
        #expect(request.systemImagePackage == "system-images;android-37.0;google_apis;arm64-v8a")
        #expect(request.sanitizedName == "My_Phone_")
    }
}

struct CommandRunnerTests {
    @Test func largeOutputDoesNotStall() async throws {
        // 200 KB is well past the 64 KB pipe buffer that used to deadlock.
        let result = try await CommandRunner().run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\\\0' a"], timeout: 10)
        #expect(result.succeeded)
        #expect(result.standardOutput.count == 200_000)
    }

    @Test func timeoutKillsTheChild() async {
        await #expect(throws: CommandRunnerError.self) {
            _ = try await CommandRunner().run("/bin/sleep", ["30"], timeout: 0.5)
        }
    }

    @Test func streamingDeliversLines() async throws {
        let lines = LockedLines()
        let code = try await CommandRunner().runStreaming("/bin/sh", ["-c", "echo one; printf 'two\\rthree\\n'"]) { lines.add($0) }
        #expect(code == 0)
        #expect(lines.all == ["one", "two", "three"])
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.withLock { storage.append(line) } }
    var all: [String] { lock.withLock { storage } }
}
