import SwiftUI

struct ContentView: View {
    let store: DeviceStore
    let ble: BLEBridgeService
    @SceneStorage("selectedSection") private var selectedSection = DeviceSection.overview.rawValue

    private var section: DeviceSection {
        DeviceSection(rawValue: selectedSection) ?? .overview
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedSection, store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            DetailView(section: section, store: store, ble: ble)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
        }
    }
}
