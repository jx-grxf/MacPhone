import Foundation

/// Downloads the open-source **BLE Radar** scanner (F-Droid `f.cking.software`) and
/// installs it onto a running Android emulator via `adb`. BLE Radar is a BLE
/// monitor with a GATT-services explorer — the ideal client for poking at the
/// device the bridge mirrors into the emulator.
struct BLERadarInstaller {
    /// F-Droid application id of the BLE Radar app.
    static let packageName = "f.cking.software"

    private let runner = CommandRunner()

    enum InstallError: LocalizedError {
        case sdkMissing
        case adbMissing
        case metadataFailed(String)
        case noVersion
        case downloadFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .sdkMissing: "Android SDK not found. Set ANDROID_HOME or install Android Studio."
            case .adbMissing: "adb not found. Install platform-tools first."
            case .metadataFailed(let m): "Could not reach F-Droid to resolve BLE Radar: \(m)"
            case .noVersion: "F-Droid returned no installable BLE Radar version."
            case .downloadFailed(let m): "Downloading BLE Radar failed: \(m)"
            case .installFailed(let m): "adb install failed: \(m)"
            }
        }
    }

    /// Resolve the APK download URL from the F-Droid package index, then download it.
    /// Streams human-readable progress to `onLog`.
    func install(onto serial: String, onLog: @escaping @Sendable (String) -> Void) async throws {
        guard let sdk = AndroidSDK.locate() else { throw InstallError.sdkMissing }
        guard sdk.hasADB else { throw InstallError.adbMissing }

        onLog("Resolving latest BLE Radar from F-Droid…")
        let apkURL = try await resolveAPKURL()

        onLog("Downloading \(apkURL.lastPathComponent)…")
        let localAPK = try await download(apkURL)
        defer { try? FileManager.default.removeItem(at: localAPK) }

        onLog("Installing BLE Radar onto \(serial)…")
        // -r reinstalls if already present; -g pre-grants runtime permissions
        // (location/bluetooth) so the scanner can run without a manual prompt.
        let result = try await runner.run(
            sdk.adbPath,
            ["-s", serial, "install", "-r", "-g", localAPK.path],
            timeout: 180,
            environment: sdk.toolEnvironment()
        )
        let output = (result.standardOutput + "\n" + result.standardError)
        guard result.succeeded, output.localizedCaseInsensitiveContains("Success") else {
            throw InstallError.installFailed(output.trimmedOneLine)
        }
        onLog("BLE Radar installed. Open it in the emulator to scan for the bridged device.")
    }

    /// Query F-Droid's package API for the suggested version code and build the
    /// canonical repo APK URL: `https://f-droid.org/repo/<pkg>_<versionCode>.apk`.
    private func resolveAPKURL() async throws -> URL {
        guard let api = URL(string: "https://f-droid.org/api/v1/packages/\(Self.packageName)") else {
            throw InstallError.metadataFailed("bad URL")
        }
        let data: Data
        do {
            let (payload, response) = try await URLSession.shared.data(from: api)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError.metadataFailed("HTTP \(http.statusCode)")
            }
            data = payload
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.metadataFailed(error.localizedDescription)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.metadataFailed("unreadable response")
        }
        // Prefer the suggested version code; fall back to the newest listed package.
        let versionCode = (json["suggestedVersionCode"] as? Int)
            ?? (json["packages"] as? [[String: Any]])?
                .compactMap { $0["versionCode"] as? Int }
                .max()
        guard let versionCode, versionCode > 0 else { throw InstallError.noVersion }

        guard let url = URL(string: "https://f-droid.org/repo/\(Self.packageName)_\(versionCode).apk") else {
            throw InstallError.downloadFailed("bad APK URL")
        }
        return url
    }

    private func download(_ url: URL) async throws -> URL {
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError.downloadFailed("HTTP \(http.statusCode)")
            }
            // Give the temp file an .apk extension so adb is happy.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("ble-radar-\(UUID().uuidString).apk")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            return dest
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
    }
}
