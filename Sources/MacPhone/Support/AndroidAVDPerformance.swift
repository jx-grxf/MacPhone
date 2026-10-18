import Foundation

/// Hardware settings for AVDs that MacPhone created. AVDs made elsewhere (Android Studio)
/// keep whatever the user configured there.
enum AndroidAVDPerformance {
    private static let managedKey = "android.managedAVDs"

    static func markManaged(_ name: String) {
        var names = Set(UserDefaults.standard.stringArray(forKey: managedKey) ?? [])
        names.insert(name)
        UserDefaults.standard.set(Array(names).sorted(), forKey: managedKey)
    }

    static func forget(_ name: String) {
        let names = (UserDefaults.standard.stringArray(forKey: managedKey) ?? []).filter { $0 != name }
        UserDefaults.standard.set(names, forKey: managedKey)
    }

    static func isManaged(_ name: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: managedKey)?.contains(name) == true
    }

    /// Pins the GPU to the host (Metal through ANGLE). The emulator's `auto` mode falls back
    /// to SwiftShader on Apple silicon often enough to make the VM crawl.
    static func applyIfManaged(toAVDNamed name: String) {
        guard isManaged(name) else { return }
        try? apply(toAVDNamed: name)
    }

    static func apply(toAVDNamed name: String) throws {
        let config = AndroidSDK.avdDirectory(named: name).appendingPathComponent("config.ini")
        let contents = try String(contentsOf: config, encoding: .utf8)
        try updated(contents, values: recommendedValues()).write(to: config, atomically: true, encoding: .utf8)
    }

    static func recommendedValues() -> [String: String] {
        let cores = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let memoryGiB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return [
            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": "host",
            "hw.cpu.ncore": String(cores),
            "hw.ramSize": memoryGiB >= 16 ? "3072" : "2048",
            "vm.heapSize": "384M",
            "hw.keyboard": "yes",
        ]
    }

    static func updated(_ contents: String, values: [String: String]) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            if let index = lines.firstIndex(where: { $0.split(separator: "=", maxSplits: 1).first.map(String.init) == key }) {
                lines[index] = "\(key)=\(value)"
            } else {
                lines.append("\(key)=\(value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
