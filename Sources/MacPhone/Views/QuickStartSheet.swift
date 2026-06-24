import SwiftUI
import AppKit

/// One-click "Install Pixel + BLE Radar" flow: creates a Play-enabled Pixel
/// emulator, boots it, waits for Android, and installs the BLE Radar scanner —
/// streaming every step into the shared provision log.
struct QuickStartSheet: View {
    let store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Pixel + BLE Radar")
                .font(.title2.weight(.semibold))

            Text("Creates a Play-enabled Pixel emulator, boots it, and installs the "
                 + "BLE Radar scanner so you can connect to the bridged device right away.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            progressSection

            Divider()
            footer
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 420, idealHeight: 480)
        .onAppear {
            // Auto-start the flow once when opened fresh; closing/reopening keeps
            // the existing log rather than restarting.
            if !store.isProvisioning && store.provisionLog.isEmpty {
                Task { await store.installDefaultPixelWithRadar() }
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if store.isProvisioning {
                    ProgressView().controlSize(.small)
                    Text("This can take several minutes the first time.")
                        .foregroundStyle(.secondary)
                } else if let error = store.provisionError {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                } else if store.provisionFinished {
                    Label("Pixel booted with BLE Radar installed.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(store.provisionLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: store.provisionLog.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if !store.provisionLog.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.provisionLog.joined(separator: "\n"), forType: .string)
                } label: { Label("Copy Log", systemImage: "doc.on.doc") }
                    .controlSize(.small)
            }
            Spacer()
            if store.isProvisioning {
                Text("Runs in the background — you can close this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(store.isProvisioning ? "Close" : "Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
