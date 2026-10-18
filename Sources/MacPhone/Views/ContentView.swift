import SwiftUI

struct ContentView: View {
    let store: DeviceStore
    let setup: SetupStore
    let ble: BLEBridgeService
    @SceneStorage("section") private var selection = AppSection.bridge.rawValue

    private var section: AppSection { AppSection(rawValue: selection) ?? .bridge }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, store: store, setup: setup, ble: ble)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .navigationTitle(section.title)
        }
        .task {
            ble.start()
            async let devices: Void = store.refresh()
            async let checks: Void = setup.check()
            _ = await (devices, checks)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .bridge:
            BridgeView(ble: ble, setup: setup, showSetup: { selection = AppSection.setup.rawValue })
        case .running:
            RunningView(store: store, ble: ble, setup: setup, select: { selection = $0.rawValue })
        case .android:
            DeviceListView(platform: .android, store: store)
        case .simulators:
            DeviceListView(platform: .apple, store: store)
        case .setup:
            SetupView(setup: setup, onChange: { Task { await store.refresh() } })
        }
    }
}
