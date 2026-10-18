import SwiftUI

/// What is live right now across both platforms, plus anything that blocks work.
struct RunningView: View {
    let store: DeviceStore
    let ble: BLEBridgeService
    let setup: SetupStore
    let select: (AppSection) -> Void

    var body: some View {
        Group {
            if store.runningDevices.isEmpty && store.issues.isEmpty && setup.missingRequired.isEmpty && !ble.isMirroring {
                ContentUnavailableView {
                    Label("Nothing Running", systemImage: "play.circle")
                } description: {
                    Text("Start an emulator or simulator and it shows up here.")
                } actions: {
                    HStack {
                        Button("Android Emulators") { select(.android) }
                        Button("Simulators") { select(.simulators) }
                    }
                }
            } else {
                List {
                    if ble.isMirroring {
                        Section("Bluetooth Bridge") {
                            Button { select(.bridge) } label: {
                                HStack {
                                    Label(ble.mirrorSourceName ?? "Mirror running", systemImage: "dot.radiowaves.left.and.right")
                                    Spacer()
                                    StatusLabel(
                                        title: ble.isEmulatorConnected ? "App connected" : "Waiting for an app",
                                        symbol: ble.isEmulatorConnected ? "checkmark.circle.fill" : "ellipsis.circle.fill",
                                        tint: ble.isEmulatorConnected ? .green : .orange
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !store.runningDevices.isEmpty {
                        Section("Devices") {
                            ForEach(store.runningDevices) { device in
                                DeviceRow(device: device, store: store)
                            }
                        }
                    }

                    let problems = setup.missingRequired.map(\.title).map { "\($0) is missing." } + store.issues.map(\.message)
                    if !problems.isEmpty {
                        Section("Needs Attention") {
                            ForEach(Array(Set(problems)).sorted(), id: \.self) { problem in
                                Label(problem, systemImage: "exclamationmark.triangle")
                                    .symbolRenderingMode(.multicolor)
                            }
                            Button("Open Setup") { select(.setup) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = store.notice {
                NoticeBar(notice: notice) { store.notice = nil }
            }
        }
    }
}
