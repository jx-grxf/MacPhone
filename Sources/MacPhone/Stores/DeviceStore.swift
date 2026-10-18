import Foundation
import Observation
import AppKit

/// Lines of a long-running job, capped so a chatty `sdkmanager` cannot grow it forever.
struct LiveLog: Equatable {
    private(set) var lines: [String] = []

    mutating func append(_ line: String) {
        lines.append(line)
        if lines.count > 800 { lines.removeFirst(lines.count - 800) }
    }

    mutating func reset(_ first: String? = nil) {
        lines = first.map { [$0] } ?? []
    }

    var text: String { lines.joined(separator: "\n") }
}

/// A job shown in a sheet: running, finished, or failed, with its log.
struct JobState: Equatable {
    var isRunning = false
    var finished = false
    var error: String?
    var log = LiveLog()

    mutating func begin(_ first: String) {
        var log = LiveLog()
        log.append(first)
        self = JobState(isRunning: true, log: log)
    }
}

@Observable
@MainActor
final class DeviceStore {
    private let simulators = SimulatorService()
    private let android = AndroidService()
    private let provisioner = AndroidProvisioner()

    private(set) var devices: [MobileDevice] = []
    private(set) var issues: [DiscoveryIssue] = []
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private var refreshRequested = false
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private(set) var busyDeviceIDs: Set<String> = []
    /// The last action's outcome, shown as a banner until dismissed.
    var notice: Notice?

    var androidJob = JobState()
    var simulatorJob = JobState()
    private(set) var simulatorCatalog = SimulatorService.Catalog.empty
    private(set) var isLoadingCatalog = false
    private(set) var isRuntimeDownloadRunning = false

    var bootWithoutWindow: Bool {
        get { UserDefaults.standard.bool(forKey: "android.bootWithoutWindow") }
        set { UserDefaults.standard.set(newValue, forKey: "android.bootWithoutWindow") }
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let isError: Bool
        let message: String
        var revealURL: URL?
    }

    var androidDevices: [MobileDevice] { devices.filter { $0.platform == .android } }
    var simulatorDevices: [MobileDevice] { devices.filter { $0.platform == .apple } }
    var runningDevices: [MobileDevice] { devices.filter { $0.isRunning || $0.isTransitioning } }

    func isBusy(_ device: MobileDevice) -> Bool { busyDeviceIDs.contains(device.id) }

    // MARK: Refresh

    /// A refresh requested while one runs is queued, not dropped, and the caller still waits
    /// for fresh data: code that refreshes and then looks up a device it just created must
    /// not read the old list.
    func refresh() async {
        if let running = refreshTask {
            refreshRequested = true
            await running.value
            return
        }
        let task = Task { await runRefreshLoop() }
        refreshTask = task
        await task.value
        refreshTask = nil
        pollWhileTransitioning()
    }

    private func runRefreshLoop() async {
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            async let apple = simulators.discover()
            async let droid = android.discover()
            let results = await [apple, droid]
            devices = results.flatMap(\.devices).sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            issues = results.flatMap(\.issues)
        } while refreshRequested
        hasLoaded = true
    }

    /// Emulators take 30–60 s to come online; keep the list honest while they do.
    private func pollWhileTransitioning() {
        pollTask?.cancel()
        guard devices.contains(where: \.isTransitioning) || !busyDeviceIDs.isEmpty else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Lifecycle actions

    func boot(_ device: MobileDevice, coldBoot: Bool = false) async {
        await perform(device, success: nil) {
            switch device.kind {
            case .simulator:
                try await self.simulators.boot(device.identifier)
            case .avd:
                try await self.android.boot(avd: device.identifier, options: .init(withoutWindow: self.bootWithoutWindow, coldBoot: coldBoot))
            case .adbOnly:
                break
            }
        }
    }

    func stop(_ device: MobileDevice) async {
        await perform(device, success: nil) {
            switch device.kind {
            case .simulator: try await self.simulators.shutdown(device.identifier)
            case .avd, .adbOnly:
                guard let serial = device.serial else { return }
                try await self.android.stop(serial: serial)
            }
        }
    }

    func erase(_ device: MobileDevice) async {
        await perform(device, success: "\(device.name) was reset.") {
            switch device.kind {
            case .simulator:
                try await self.simulators.erase(device.identifier, isRunning: device.isRunning)
            case .avd:
                try await self.android.wipe(avd: device.identifier, runningSerial: device.serial,
                                            options: .init(withoutWindow: self.bootWithoutWindow))
            case .adbOnly:
                break
            }
        }
    }

    func delete(_ device: MobileDevice) async {
        await perform(device, success: "\(device.name) was deleted.") {
            switch device.kind {
            case .simulator: try await self.simulators.delete(device.identifier, isRunning: device.isRunning)
            case .avd: try await self.android.delete(avd: device.identifier, runningSerial: device.serial)
            case .adbOnly: break
            }
        }
    }

    func rename(_ device: MobileDevice, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard device.kind == .simulator, !trimmed.isEmpty else { return }
        await perform(device, success: nil) { try await self.simulators.rename(device.identifier, to: trimmed) }
    }

    func duplicate(_ device: MobileDevice) async {
        guard device.kind == .simulator else { return }
        await perform(device, success: "Duplicated \(device.name).") {
            try await self.simulators.clone(device.identifier, as: "\(device.name) Copy")
        }
    }

    func deleteUnavailableSimulators() async {
        do {
            try await simulators.deleteUnavailable()
            notice = Notice(isError: false, message: "Removed simulators whose runtime is gone.")
        } catch {
            notice = Notice(isError: true, message: error.localizedDescription)
        }
        await refresh()
    }

    // MARK: Testing helpers

    func show(_ device: MobileDevice) async {
        guard device.kind == .simulator else { return }
        try? await simulators.show(device.identifier)
    }

    func install(_ file: URL, on device: MobileDevice) async {
        let isApp = file.pathExtension == "app" || file.pathExtension == "ipa"
        let isAPK = file.pathExtension == "apk"
        guard (device.platform == .apple && isApp) || (device.platform == .android && isAPK) else {
            notice = Notice(isError: true, message: device.platform == .apple
                ? "Simulators install .app bundles built for the simulator."
                : "Android emulators install .apk files.")
            return
        }
        await perform(device, success: "Installed \(file.lastPathComponent) on \(device.name).", refreshAfter: false) {
            if device.platform == .apple {
                try await self.simulators.install(file, on: device.identifier)
            } else {
                try await self.android.install(file, serial: try self.serial(of: device))
            }
        }
    }

    func open(_ url: String, on device: MobileDevice) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform(device, success: nil, refreshAfter: false) {
            if device.platform == .apple {
                try await self.simulators.open(trimmed, on: device.identifier)
            } else {
                try await self.android.open(trimmed, serial: try self.serial(of: device))
            }
        }
    }

    func screenshot(_ device: MobileDevice) async {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let file = desktop.appendingPathComponent("\(device.name) \(stamp).png")
        await perform(device, success: "Saved the screenshot to the Desktop.", refreshAfter: false) {
            if device.platform == .apple {
                try await self.simulators.screenshot(device.identifier, to: file)
            } else {
                try await self.android.screenshot(serial: try self.serial(of: device), to: file)
            }
        }
        if notice?.isError == false { notice?.revealURL = file }
    }

    func setAppearance(dark: Bool, on device: MobileDevice) async {
        await perform(device, success: nil, refreshAfter: false) {
            if device.platform == .apple {
                try await self.simulators.setAppearance(dark: dark, on: device.identifier)
            } else {
                try await self.android.setAppearance(dark: dark, serial: try self.serial(of: device))
            }
        }
    }

    func setCleanStatusBar(_ enabled: Bool, on device: MobileDevice) async {
        guard device.kind == .simulator else { return }
        await perform(device, success: nil, refreshAfter: false) {
            try await self.simulators.setCleanStatusBar(enabled, on: device.identifier)
        }
    }

    private nonisolated func serial(of device: MobileDevice) throws -> String {
        guard let serial = device.serial, device.isRunning else { throw AndroidService.AndroidError.notRunning }
        return serial
    }

    private func perform(
        _ device: MobileDevice,
        success: String?,
        refreshAfter: Bool = true,
        _ action: @escaping () async throws -> Void
    ) async {
        guard !busyDeviceIDs.contains(device.id) else { return }
        busyDeviceIDs.insert(device.id)
        defer { busyDeviceIDs.remove(device.id) }
        do {
            try await action()
            if let success { notice = Notice(isError: false, message: success) }
        } catch {
            notice = Notice(isError: true, message: error.localizedDescription)
        }
        if refreshAfter { await refresh() }
    }

    // MARK: Creating devices

    func createAndroidEmulator(_ request: AndroidProvisioner.Request, bootAfterCreate: Bool) async {
        guard !androidJob.isRunning else { return }
        androidJob.begin("Starting.")
        let onLine: @Sendable (String) -> Void = { line in Task { @MainActor in self.androidJob.log.append(line) } }
        do {
            try await provisioner.provision(request, onLog: onLine)
            androidJob.finished = true
        } catch {
            androidJob.error = error.localizedDescription
        }
        androidJob.isRunning = false
        await refresh()
        if bootAfterCreate, androidJob.finished,
           let device = androidDevices.first(where: { $0.identifier == request.sanitizedName }) {
            await boot(device)
        }
    }

    func loadSimulatorCatalog() async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        isRuntimeDownloadRunning = await SimulatorService.runtimeDownloadInProgress()
        do {
            simulatorCatalog = try await simulators.catalog()
        } catch {
            simulatorCatalog = .empty
            simulatorJob.error = error.localizedDescription
        }
    }

    func createSimulator(_ request: SimulatorService.CreateRequest, bootAfterCreate: Bool) async {
        guard !simulatorJob.isRunning else { return }
        simulatorJob.begin("Creating \(request.name).")
        do {
            let udid = try await simulators.create(request)
            simulatorJob.log.append("Created \(request.name).")
            simulatorJob.finished = true
            simulatorJob.isRunning = false
            await refresh()
            if bootAfterCreate, let device = simulatorDevices.first(where: { $0.identifier == udid }) {
                await boot(device)
            }
        } catch {
            simulatorJob.error = error.localizedDescription
            simulatorJob.isRunning = false
        }
    }

    func downloadSimulatorRuntime(_ platform: String) async {
        guard !simulatorJob.isRunning else { return }
        simulatorJob.begin("Downloading the \(platform) runtime from Apple. This takes a while.")
        isRuntimeDownloadRunning = true
        let onLine: @Sendable (String) -> Void = { line in Task { @MainActor in self.simulatorJob.log.append(line) } }
        do {
            try await simulators.downloadRuntime(platform: platform, onLine: onLine)
            simulatorJob.log.append("\(platform) runtime installed.")
        } catch {
            simulatorJob.error = error.localizedDescription
        }
        simulatorJob.isRunning = false
        isRuntimeDownloadRunning = false
        await loadSimulatorCatalog()
    }
}
