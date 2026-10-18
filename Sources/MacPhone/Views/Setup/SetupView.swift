import SwiftUI
import AppKit

struct SetupView: View {
    let setup: SetupStore
    let onChange: () -> Void

    var body: some View {
        Form {
            ForEach(Dependency.Group.allCases, id: \.self) { group in
                let items = setup.dependencies.filter { $0.group == group }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { DependencyRow(setup: setup, dependency: $0, onChange: onChange) }
                    } header: {
                        Text(group.rawValue)
                    } footer: {
                        Text(footer(for: group))
                    }
                }
            }

            if !setup.job.log.lines.isEmpty {
                Section {
                    LogView(lines: setup.job.log.lines, minHeight: 160)
                        .frame(maxHeight: 240)
                        .listRowInsets(EdgeInsets())
                } header: {
                    HStack {
                        if setup.job.isRunning {
                            Label { Text("Installing") } icon: { ProgressView().controlSize(.mini) }
                        } else if let error = setup.job.error {
                            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        } else {
                            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Spacer()
                        Button("Copy Log") { copyToPasteboard(setup.job.log.text) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if setup.dependencies.isEmpty { ProgressView("Checking this Mac") }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await setup.check() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(setup.isChecking || setup.runningFixID != nil)
            }
        }
        .task { await setup.check() }
    }

    private func footer(for group: Dependency.Group) -> String {
        switch group {
        case .bridge: "The bridge runs in its own Python environment in ~/Library/Application Support/MacPhone."
        case .android: "Installed into the Android SDK folder. Android Studio is optional."
        case .apple: "Only the iOS runtime is needed for iPhone and iPad simulators."
        }
    }
}

private struct DependencyRow: View {
    let setup: SetupStore
    let dependency: Dependency
    let onChange: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityLabel(dependency.satisfied ? "Installed" : "Missing")
            VStack(alignment: .leading, spacing: 2) {
                Text(dependency.title)
                Text(dependency.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !dependency.satisfied, let label = dependency.fix.label {
                if setup.runningFixID == dependency.id {
                    ProgressView().controlSize(.small)
                } else if case .link(let url) = dependency.fix {
                    Button(label) { NSWorkspace.shared.open(url) }
                } else {
                    Button(label) {
                        Task {
                            await setup.runFix(for: dependency)
                            onChange()
                        }
                    }
                    .disabled(setup.runningFixID != nil)
                }
            }
        }
    }

    private var symbol: String {
        if dependency.satisfied { return "checkmark.circle.fill" }
        return dependency.required ? "exclamationmark.circle.fill" : "circle.dashed"
    }

    private var tint: Color {
        if dependency.satisfied { return .green }
        return dependency.required ? .orange : .secondary
    }
}
