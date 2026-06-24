import SwiftUI

struct SidebarView: View {
    @Binding var selection: String
    let store: DeviceStore

    var body: some View {
        List(selection: $selection) {
            ForEach(DeviceSection.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section.rawValue)
            }

            Section("Status") {
                StatusRow(title: "Android", count: store.androidDevices.count, symbol: "app.badge")
                StatusRow(title: "iOS", count: store.iosDevices.count, symbol: "iphone")
                StatusRow(title: "Issues", count: store.issues.count, symbol: "exclamationmark.triangle")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MacPhone")
    }
}

private struct StatusRow: View {
    let title: String
    let count: Int
    let symbol: String

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
