import SwiftUI

struct SidebarView: View {
    @Binding var selection: String
    let store: DeviceStore
    let setup: SetupStore
    let ble: BLEBridgeService

    var body: some View {
        List(selection: $selection) {
            row(.bridge)
                .badge(ble.isMirroring ? Text("On") : nil)

            Section("Devices") {
                row(.running).badge(store.runningDevices.count)
                row(.android).badge(store.androidDevices.count)
                row(.simulators).badge(store.simulatorDevices.count)
            }

            Section {
                row(.setup)
                    .badge(setup.missingRequired.isEmpty ? nil : Text("\(setup.missingRequired.count) missing"))
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .tag(section.rawValue)
    }
}
