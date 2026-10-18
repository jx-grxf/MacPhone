import Foundation
import Observation

@Observable
@MainActor
final class SetupStore {
    private let service = SetupService()

    private(set) var dependencies: [Dependency] = []
    private(set) var isChecking = false
    private(set) var runningFixID: String?
    var job = JobState()

    var missingRequired: [Dependency] { dependencies.filter { $0.required && !$0.satisfied } }
    var bridgeReady: Bool { dependencies.filter { $0.group == .bridge }.allSatisfy(\.satisfied) && !dependencies.isEmpty }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        dependencies = await service.check()
    }

    func runFix(for dependency: Dependency) async {
        guard runningFixID == nil else { return }
        runningFixID = dependency.id
        job.begin("\(dependency.title): starting.")
        let onLine: @Sendable (String) -> Void = { line in Task { @MainActor in self.job.log.append(line) } }
        do {
            try await service.run(dependency.fix, onLog: onLine)
            job.finished = true
        } catch {
            job.error = error.localizedDescription
        }
        job.isRunning = false
        runningFixID = nil
        await check()
    }
}
