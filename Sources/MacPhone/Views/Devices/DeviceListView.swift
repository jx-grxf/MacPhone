import SwiftUI
import UniformTypeIdentifiers

struct DeviceListView: View {
    let platform: MobilePlatform
    let store: DeviceStore

    @State private var search = ""
    @State private var runningOnly = false
    @State private var showCreate = false

    private var devices: [MobileDevice] {
        let base = platform == .apple ? store.simulatorDevices : store.androidDevices
        return base.filter { device in
            (!runningOnly || device.isRunning || device.isTransitioning)
                && (search.isEmpty
                    || device.name.localizedCaseInsensitiveContains(search)
                    || device.osVersion.localizedCaseInsensitiveContains(search))
        }
    }

    private var groups: [(title: String, devices: [MobileDevice])] {
        if platform == .android {
            let emulators = devices.filter { $0.kind == .avd }
            let others = devices.filter { $0.kind == .adbOnly }
            return [("Emulators", emulators), ("Connected over adb", others)].filter { !$0.devices.isEmpty }
        }
        return DeviceFamily.allCases.compactMap { family in
            let members = devices.filter { $0.family == family }
            return members.isEmpty ? nil : (family.title, members)
        }
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = store.notice {
                    NoticeBar(notice: notice) { store.notice = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Design.Motion.expand, value: store.notice)
            .searchable(text: $search, placement: .toolbar, prompt: platform == .apple ? "Search simulators" : "Search emulators")
            .toolbar { toolbar }
            .sheet(isPresented: $showCreate) {
                if platform == .apple {
                    SimulatorCreateSheet(store: store)
                } else {
                    AndroidProvisionSheet(store: store)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if devices.isEmpty {
            emptyState
        } else {
            List {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.devices) { device in
                            DeviceRow(device: device, store: store)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.isEmpty || runningOnly {
            ContentUnavailableView.search(text: search)
        } else if platform == .android {
            ContentUnavailableView {
                Label("No Android Emulators", systemImage: "smartphone")
            } description: {
                Text(store.issues.first?.message ?? "Create one with a current Android image. MacPhone downloads it for you.")
            } actions: {
                Button("Create Emulator…") { showCreate = true }
            }
        } else {
            ContentUnavailableView {
                Label("No Simulators", systemImage: "iphone")
            } description: {
                Text("Create a simulator for any installed iOS, watchOS, tvOS or visionOS runtime.")
            } actions: {
                Button("Create Simulator…") { showCreate = true }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Toggle(isOn: $runningOnly) {
                Label("Running Only", systemImage: "play.circle")
            }
            .help("Show only running devices")
        }
        if platform == .apple {
            ToolbarItem {
                Menu {
                    Button("Remove Simulators Without a Runtime") {
                        Task { await store.deleteUnavailableSimulators() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        } else {
            ToolbarItem {
                Menu {
                    Toggle("Start Without a Window", isOn: Binding(
                        get: { store.bootWithoutWindow },
                        set: { store.bootWithoutWindow = $0 }
                    ))
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                .help("Emulators started without a window use software rendering and run in the background.")
            }
        }
        ToolbarItem {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .disabled(store.isRefreshing)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showCreate = true
            } label: {
                Label(platform == .apple ? "Create Simulator" : "Create Emulator", systemImage: "plus")
            }
        }
    }
}

struct DeviceRow: View {
    let device: MobileDevice
    let store: DeviceStore

    @State private var isHovered = false
    @State private var isDropTarget = false
    @State private var dialog: Dialog?
    @State private var textInput = ""
    @State private var showInstallPicker = false

    enum Dialog: String, Identifiable {
        case erase, delete, openURL, rename
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Image(systemName: device.family.symbol)
                .font(.title2)
                .foregroundStyle(device.isRunning ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(device.osVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Design.Space.m)

            if store.isBusy(device) {
                ProgressView().controlSize(.small)
            }
            StatusLabel(title: device.state.title, symbol: device.state.symbol, tint: device.state.tint)
                .frame(width: 96, alignment: .leading)

            primaryButton
                .frame(width: 64)

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0.5)
            .accessibilityLabel("Actions for \(device.name)")
        }
        .padding(.vertical, Design.Space.xs)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Design.Motion.hover) { isHovered = hovering } }
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
        )
        .contextMenu { actions }
        .onTapGesture(count: 2) {
            if device.isRunning { Task { await store.show(device) } }
            else if device.canBoot { Task { await store.boot(device) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, device.isRunning else { return false }
            Task { await store.install(url, on: device) }
            return true
        } isTargeted: { isDropTarget = $0 && device.isRunning }
        .help(device.isRunning ? "Drop an \(device.platform == .apple ? ".app" : ".apk") here to install it." : "")
        .fileImporter(isPresented: $showInstallPicker, allowedContentTypes: installTypes) { result in
            if case .success(let url) = result { Task { await store.install(url, on: device) } }
        }
        .alert(alertTitle, isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }), presenting: dialog) { kind in
            alertActions(kind)
        } message: { kind in
            alertMessage(kind)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if device.canStop {
            Button("Stop") { Task { await store.stop(device) } }
                .disabled(store.isBusy(device))
        } else if device.canBoot {
            Button("Start") { Task { await store.boot(device) } }
                .disabled(store.isBusy(device))
        } else {
            Color.clear
        }
    }

    private var installTypes: [UTType] {
        device.platform == .apple
            ? [.applicationBundle]
            : [UTType(filenameExtension: "apk") ?? .data]
    }

    @ViewBuilder
    private var actions: some View {
        if device.canBoot {
            Button("Start") { Task { await store.boot(device) } }
            if device.kind == .avd {
                Button("Cold Start") { Task { await store.boot(device, coldBoot: true) } }
            }
        }
        if device.canStop {
            Button("Stop") { Task { await store.stop(device) } }
        }
        if device.kind == .simulator, device.isRunning {
            Button("Show in Simulator") { Task { await store.show(device) } }
        }

        Divider()

        Group {
            Button("Install App…") { showInstallPicker = true }
            Button("Open URL…") { textInput = ""; dialog = .openURL }
            Button("Take Screenshot") { Task { await store.screenshot(device) } }
            Menu("Appearance") {
                Button("Light") { Task { await store.setAppearance(dark: false, on: device) } }
                Button("Dark") { Task { await store.setAppearance(dark: true, on: device) } }
            }
            if device.kind == .simulator {
                Menu("Status Bar") {
                    Button("Clean (9:41, Full Battery)") { Task { await store.setCleanStatusBar(true, on: device) } }
                    Button("Reset") { Task { await store.setCleanStatusBar(false, on: device) } }
                }
            }
        }
        .disabled(!device.isRunning)

        Divider()

        Button(device.kind == .simulator ? "Copy UDID" : "Copy Name") { copyToPasteboard(device.identifier) }
        if device.kind == .simulator {
            Button("Rename…") { textInput = device.name; dialog = .rename }
            Button("Duplicate") { Task { await store.duplicate(device) } }
        }
        if device.canErase {
            Button("Erase Contents…", role: .destructive) { dialog = .erase }
        }
        if device.canDelete {
            Button("Delete…", role: .destructive) { dialog = .delete }
        }
    }

    private var alertTitle: String {
        switch dialog {
        case .erase: "Erase “\(device.name)”?"
        case .delete: "Delete “\(device.name)”?"
        case .openURL: "Open a URL on \(device.name)"
        case .rename: "Rename \(device.name)"
        case nil: ""
        }
    }

    @ViewBuilder
    private func alertActions(_ kind: Dialog) -> some View {
        switch kind {
        case .erase:
            Button("Erase", role: .destructive) { Task { await store.erase(device) } }
            Button("Cancel", role: .cancel) {}
        case .delete:
            Button("Delete", role: .destructive) { Task { await store.delete(device) } }
            Button("Cancel", role: .cancel) {}
        case .openURL:
            TextField("https://example.com or myapp://path", text: $textInput)
            Button("Open") { Task { await store.open(textInput, on: device) } }
            Button("Cancel", role: .cancel) {}
        case .rename:
            TextField("Name", text: $textInput)
            Button("Rename") { Task { await store.rename(device, to: textInput) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func alertMessage(_ kind: Dialog) -> some View {
        switch kind {
        case .erase:
            Text(device.kind == .avd
                 ? "All apps and data on this emulator are removed. It starts fresh afterwards."
                 : "All apps and data on this simulator are removed.")
        case .delete:
            Text("The device and everything on it are removed. This can't be undone.")
        case .openURL:
            Text("Web links open in the browser, custom schemes open the app that handles them.")
        case .rename:
            EmptyView()
        }
    }
}
