import SwiftUI

struct SidebarView: View {
    @Binding var selection: String
    let store: DeviceStore
    let setup: SetupStore
    let ble: BLEBridgeService

    var body: some View {
        List(selection: $selection) {
            row(.bridge, badge: ble.isMirroring ? Text("On") : nil)

            Section("Devices") {
                row(.running, badge: Text("\(store.runningDevices.count)"))
                row(.android, badge: Text("\(store.androidDevices.count)"))
                row(.simulators, badge: Text("\(store.simulatorDevices.count)"))
            }

            Section {
                row(.setup, badge: setup.missingRequired.isEmpty ? nil : Text("\(setup.missingRequired.count) missing"))
            }
        }
        .listStyle(.sidebar)
    }

    /// The tag has to be the outermost modifier, or List cannot match the row to the selection.
    private func row(_ section: AppSection, badge: Text?) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge)
            .tag(section.rawValue)
    }
}
