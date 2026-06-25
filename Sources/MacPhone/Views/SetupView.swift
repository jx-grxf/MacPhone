import SwiftUI
import AppKit

/// Onboarding / health panel: shows whether every prerequisite is present and installs the
/// missing ones with one click, so a non-technical user can get the fleet running.
struct SetupView: View {
    let store: DeviceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(spacing: 0) {
                    ForEach(Array(store.dependencies.enumerated()), id: \.element.id) { index, dep in
                        DependencyRow(store: store, dependency: dep)
                        if index < store.dependencies.count - 1 { Divider() }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                if !store.setupLog.isEmpty {
                    logSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.refreshDependencies() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Get set up")
                    .font(.title2.weight(.semibold))
                Text(store.allRequiredSatisfied
                    ? "All required Android and iOS tools are installed."
                    : "Install the missing pieces below. Most are one click.")
                    .foregroundStyle(store.allRequiredSatisfied ? Color.green : Color.secondary)
            }
            Spacer()
            Button {
                store.refreshDependencies()
            } label: {
                Label("Recheck", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRunningSetup)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if store.isRunningSetup {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                } else if let error = store.setupError {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                } else {
                    Label("Done.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                Spacer()
                Button("Clear") { store.setupLog = []; store.setupError = nil }
                    .controlSize(.small)
                    .disabled(store.isRunningSetup)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(store.setupLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 180)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: store.setupLog.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }
}

private struct DependencyRow: View {
    let store: DeviceStore
    let dependency: Dependency

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: dependency.satisfied ? "checkmark.circle.fill" : (dependency.required ? "exclamationmark.circle" : "circle"))
                .foregroundStyle(dependency.satisfied ? Color.green : (dependency.required ? Color.orange : Color.secondary))
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dependency.title).font(.headline)
                    if !dependency.required {
                        Text("optional")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(dependency.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !dependency.satisfied {
                fixControl
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var fixControl: some View {
        let isThisRunning = store.runningFixID == dependency.id
        switch dependency.fix {
        case .none:
            EmptyView()
        case .manual(let label, let url, let command):
            HStack(spacing: 6) {
                if let command {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: { Label("Copy command", systemImage: "doc.on.doc") }
                        .controlSize(.small)
                }
                if let url, let link = URL(string: url) {
                    Button(label) { NSWorkspace.shared.open(link) }
                        .controlSize(.small)
                }
            }
        case .brewCask, .brewFormula, .sdkmanager, .bootstrapTools, .bridgeVenv,
             .xcodePlatform:
            Button {
                Task { await store.runFix(for: dependency) }
            } label: {
                if isThisRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(dependency.fix.label ?? "Install")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(store.isRunningSetup)
        }
    }
}
