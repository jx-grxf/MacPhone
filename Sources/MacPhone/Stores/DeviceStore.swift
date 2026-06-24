import Foundation
import Observation

@Observable
@MainActor
final class DeviceStore {
    private let android = AndroidOrchestrator()
    private let ios = IOSSimulatorOrchestrator()
    private let control = DeviceControlService()
    private let provisioner = AndroidProvisioner()
    private let setup = SetupService()

    /// Live state for the "Add Android emulator" flow.
    var isProvisioning = false
    var provisionLog: [String] = []
    var provisionError: String?
    var provisionFinished = false

    /// Setup / dependency state.
    var dependencies: [Dependency] = []
    var isRunningSetup = false
    var setupLog: [String] = []
    var setupError: String?
    var runningFixID: String?

    var allRequiredSatisfied: Bool {
        dependencies.filter(\.required).allSatisfy(\.satisfied)
    }

    var devices: [MobileDevice] = []
    var issues: [DiscoveryIssue] = []
    var isRefreshing = false

    /// Device ids currently undergoing a boot/stop action.
    var busyDeviceIDs: Set<String> = []
    /// Last control-action error, surfaced in the UI.
    var lastActionError: String?
    /// Whether new Android emulators should boot without a window.
    var bootHeadless = false

    var androidDevices: [MobileDevice] {
        devices.filter { $0.platform == .android }
    }

    var iosDevices: [MobileDevice] {
        devices.filter { $0.platform == .ios }
    }

    @MainActor
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let androidResult = android.discover()
        async let iosResult = ios.discover()

        let results = await [androidResult, iosResult]
        devices = results.flatMap(\.devices).sorted {
            if $0.platform.rawValue == $1.platform.rawValue {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.platform.rawValue < $1.platform.rawValue
        }
        issues = results.flatMap(\.issues)
    }

    func isBusy(_ device: MobileDevice) -> Bool {
        busyDeviceIDs.contains(device.id)
    }

    @MainActor
    func boot(_ device: MobileDevice) async {
        await perform(device) { try await control.boot(device, headless: bootHeadless) }
    }

    @MainActor
    func coldBoot(_ device: MobileDevice) async {
        await perform(device) { try await control.boot(device, headless: bootHeadless, coldBoot: true) }
    }

    @MainActor
    func stop(_ device: MobileDevice) async {
        await perform(device) { try await control.stop(device) }
    }

    @MainActor
    func wipe(_ device: MobileDevice) async {
        await perform(device) { try await control.wipe(device) }
    }

    // MARK: Setup / dependencies

    @MainActor
    func refreshDependencies() {
        dependencies = setup.check()
    }

    @MainActor
    func runFix(for dependency: Dependency) async {
        guard !isRunningSetup else { return }
        isRunningSetup = true
        runningFixID = dependency.id
        setupError = nil
        setupLog = ["Starting: \(dependency.fix.label ?? dependency.title)…"]
        defer {
            isRunningSetup = false
            runningFixID = nil
        }

        let onLog: @Sendable (String) -> Void = { line in
            Task { @MainActor in self.appendSetupLog(line) }
        }

        do {
            try await setup.run(dependency.fix, onLog: onLog)
        } catch {
            setupError = error.localizedDescription
            appendSetupLog("Error: \(error.localizedDescription)")
        }

        refreshDependencies()
        await refresh()
    }

    @MainActor
    private func appendSetupLog(_ line: String) {
        setupLog.append(line)
        if setupLog.count > 800 { setupLog.removeFirst(setupLog.count - 800) }
    }

    // MARK: Provisioning

    @MainActor
    func createAndroidEmulator(_ request: AndroidProvisioner.Request, bootAfterCreate: Bool = false) async {
        guard !isProvisioning else { return }
        isProvisioning = true
        provisionFinished = false
        provisionError = nil
        provisionLog = ["Starting…"]
        defer { isProvisioning = false }

        // The provisioner streams from a background task; hop each line back to the UI.
        let onLog: @Sendable (String) -> Void = { line in
            Task { @MainActor in self.appendProvisionLog(line) }
        }

        do {
            try await provisioner.provision(request, onLog: onLog)
            provisionFinished = true
        } catch {
            provisionError = error.localizedDescription
            appendProvisionLog("Error: \(error.localizedDescription)")
        }

        await refresh()

        // Optionally boot the freshly created AVD so the user doesn't have to hunt for it.
        if bootAfterCreate, provisionFinished,
           let device = androidDevices.first(where: { $0.name == request.sanitizedName }) {
            appendProvisionLog("Booting \(device.name)…")
            await boot(device)
        }
    }

    @MainActor
    private func appendProvisionLog(_ line: String) {
        provisionLog.append(line)
        if provisionLog.count > 800 { provisionLog.removeFirst(provisionLog.count - 800) }
    }

    @MainActor
    private func perform(_ device: MobileDevice, _ action: () async throws -> Void) async {
        guard !busyDeviceIDs.contains(device.id) else { return }
        busyDeviceIDs.insert(device.id)
        lastActionError = nil
        defer { busyDeviceIDs.remove(device.id) }

        do {
            try await action()
        } catch {
            lastActionError = error.localizedDescription
            return
        }

        // Emulators/simulators change state asynchronously; give them a moment, then refresh.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }
}
