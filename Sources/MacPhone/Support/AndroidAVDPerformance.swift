import Foundation

enum AndroidAVDPerformance {
    enum ConfigurationError: LocalizedError {
        case missingConfiguration(String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration(let path):
                "Android emulator configuration not found at \(path)."
            }
        }
    }

    /// Prefers the platform's accelerated CPU and GPU backends while allowing the
    /// emulator to select a compatible fallback when a specific backend is unavailable.
    static func apply(toAVDNamed name: String) throws {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".android/avd", isDirectory: true)
            .appendingPathComponent("\(name).avd", isDirectory: true)
            .appendingPathComponent("config.ini")

        guard FileManager.default.fileExists(atPath: config.path) else {
            throw ConfigurationError.missingConfiguration(config.path)
        }

        let contents = try String(contentsOf: config, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let coreCount = min(6, max(2, processorCount / 2))
        let memoryGiB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let ramMiB = memoryGiB >= 16 ? 3072 : 2048

        let performanceValues = [
            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": "auto",
            "hw.cpu.ncore": String(coreCount),
            "hw.ramSize": String(ramMiB),
            "vm.heapSize": "384M",
            "hw.keyboard": "yes"
        ]

        for (key, value) in performanceValues {
            if let index = lines.firstIndex(where: { line in
                guard let separator = line.firstIndex(of: "=") else { return false }
                return line[..<separator] == key[...]
            }) {
                lines[index] = "\(key)=\(value)"
            } else {
                lines.append("\(key)=\(value)")
            }
        }

        while lines.last?.isEmpty == true { lines.removeLast() }
        let output = lines.joined(separator: "\n") + "\n"
        try output.write(to: config, atomically: true, encoding: .utf8)
    }
}
