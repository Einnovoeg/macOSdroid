import SwiftUI
import UniformTypeIdentifiers

/// Main dashboard shown when the app is not running in menu-bar-only mode.
struct ContentView: View {
    private enum ControlPanelTab: String, CaseIterable, Identifiable {
        case runtime
        case background
        case inbox
        case launchers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .runtime: "Runtime"
            case .background: "Background"
            case .inbox: "Inbox"
            case .launchers: "Launchers"
            }
        }

        var icon: String {
            switch self {
            case .runtime: "cpu"
            case .background: "menubar.rectangle"
            case .inbox: "tray.full"
            case .launchers: "link"
            }
        }
    }

    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @State private var isInboxDropTargeted = false
    @State private var watchFolderDraft = ""
    @State private var libraryFilter = ""
    @State private var selectedTab: ControlPanelTab = .runtime

    var body: some View {
        ZStack {
            backgroundView

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    configurationTabs
                    libraryCard
                    documentationCard
                }
                .padding(24)
            }
        }
        .frame(minWidth: 920, minHeight: 720)
        .onAppear {
            syncWatchFolderDraft()
        }
        .onChange(of: model.settings.watchFolderPath) { _ in
            syncWatchFolderDraft()
        }
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.08, blue: 0.11),
                    Color(red: 0.10, green: 0.12, blue: 0.18),
                    Color(red: 0.15, green: 0.10, blue: 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.22, green: 0.63, blue: 0.62).opacity(0.22))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: -340, y: -230)

            Circle()
                .fill(Color(red: 0.87, green: 0.46, blue: 0.28).opacity(0.20))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: 320, y: -260)

            RoundedRectangle(cornerRadius: 48, style: .continuous)
                .fill(Color.white.opacity(0.02))
                .frame(width: 720, height: 720)
                .rotationEffect(.degrees(12))
                .blur(radius: 1)
                .offset(x: 360, y: 320)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("macOSdroid")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    HStack(spacing: 10) {
                        heroChip(title: model.runtimeState.title, icon: runtimeIcon, tint: statusColor)

                        if let device = model.connectedDevice {
                            heroChip(title: device, icon: "cpu", tint: Color.white.opacity(0.88))
                        }

                        heroChip(
                            title: model.settings.menuBarOnly ? "Menu Bar Mode" : "Dashboard Mode",
                            icon: model.settings.menuBarOnly ? "menubar.rectangle" : "macwindow",
                            tint: Color(red: 0.93, green: 0.78, blue: 0.43)
                        )
                    }
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 12) {
                    Button("Start Runtime") {
                        model.startRuntime()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.29, green: 0.77, blue: 0.66))
                    .disabled(!model.canStart)
                    .help("Boot the managed Android runtime in the background.")

                    Button("Stop Runtime") {
                        model.stopRuntime()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canStop)
                    .help("Shut down the managed Android runtime and disconnect active device sessions.")

                    Button("Open Activity Log") {
                        openWindow(id: "activity-log")
                    }
                    .buttonStyle(.bordered)
                    .help("Open the separate diagnostics window with install, launch, and runtime events.")

                    Text(model.statusMessage)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.70))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
            }

            HStack(spacing: 12) {
                metricTile(title: "Library", value: "\(model.folderApps.count)", caption: "APK files in inbox", tint: Color(red: 0.29, green: 0.77, blue: 0.66))
                metricTile(title: "Installed", value: "\(model.installedFolderAppCount)", caption: "packages ready to launch", tint: Color(red: 0.93, green: 0.78, blue: 0.43))
                metricTile(title: "Inbox", value: watchFolderName, caption: "current watch folder", tint: Color(red: 0.54, green: 0.62, blue: 0.95))
                metricTile(title: "Launchers", value: model.folderApps.filter { $0.packageName != nil }.isEmpty ? "0" : "Ready", caption: "Finder shortcuts export", tint: Color(red: 0.87, green: 0.46, blue: 0.28))
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 24, y: 16)
    }

    private var configurationTabs: some View {
        VStack(alignment: .leading, spacing: 16) {
            tabSelector
            selectedConfigurationCard
        }
    }

    private var tabSelector: some View {
        HStack(spacing: 10) {
            ForEach(ControlPanelTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
    }

    @ViewBuilder
    private var selectedConfigurationCard: some View {
        switch selectedTab {
        case .runtime:
            runtimeCard
        case .background:
            behaviorCard
        case .inbox:
            folderCard
        case .launchers:
            launcherCard
        }
    }

    private func tabButton(for tab: ControlPanelTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            selectedTab = tab
        } label: {
            Label(tab.title, systemImage: tab.icon)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.76))
        .help("Open the \(tab.title.lowercased()) controls.")
    }

    private var runtimeCard: some View {
        card(title: "Runtime", subtitle: "Configure the managed runtime, prepare it inside Application Support, and open dedicated views for emulator or phone sessions.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("Android SDK path", text: Binding(
                        get: { model.settings.sdkRootPath },
                        set: { model.updateSDKPath($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("The Android SDK root used for the managed runtime and APK inspection tools.")

                    Button("Browse") {
                        model.chooseSDKFolder()
                    }
                    .buttonStyle(.bordered)
                    .help("Pick a different Android SDK root.")

                    Button("Refresh AVDs") {
                        Task {
                            await model.refreshAVDs()
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Reload the list of Android virtual devices available in the configured SDK.")
                }

                HStack(spacing: 10) {
                    Button(model.isProvisioningRuntime ? "Preparing Runtime" : "Prepare Managed Runtime") {
                        model.provisionManagedRuntime()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.54, green: 0.62, blue: 0.95))
                    .disabled(model.isProvisioningRuntime || !(model.runtimeState == .stopped || model.runtimeState == .failed))
                    .help("Install or refresh the managed Android SDK, AVD, and helper tools inside Application Support.")

                    Button("Open Support Folder") {
                        model.revealApplicationSupportFolder()
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal the Application Support folder that stores the managed runtime.")

                    Button("Open Log File") {
                        model.revealActivityLogFile()
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal the persisted activity log in Finder.")
                }

                HStack(spacing: 10) {
                    if model.availableAVDs.isEmpty {
                        TextField("AVD name", text: Binding(
                            get: { model.settings.avdName },
                            set: { model.updateAVDName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .help("Enter the name of the Android virtual device to boot.")
                    } else {
                        Picker("Virtual Device", selection: Binding(
                            get: { model.settings.avdName },
                            set: { model.updateAVDName($0) }
                        )) {
                            ForEach(model.availableAVDs, id: \.self) { avd in
                                Text(avd).tag(avd)
                            }
                        }
                        .pickerStyle(.menu)
                        .help("Choose which Android virtual device macOSdroid should boot.")
                    }

                    Toggle("Auto-start runtime on launch", isOn: Binding(
                        get: { model.settings.autoStartRuntime },
                        set: { model.toggleAutoStart($0) }
                    ))
                    .toggleStyle(.switch)
                    .help("Start the managed runtime automatically when macOSdroid launches.")
                }

                Toggle("Show Android window when launching apps", isOn: Binding(
                    get: { model.settings.showAndroidWindow },
                    set: { model.toggleShowAndroidWindow($0) }
                ))
                .toggleStyle(.switch)
                .help("Use the full emulator window instead of keeping the runtime display hidden.")

                Toggle("Open Android apps in their own windows when scrcpy is available", isOn: Binding(
                    get: { model.settings.preferSeparateAppWindows },
                    set: { model.togglePreferSeparateAppWindows($0) }
                ))
                .toggleStyle(.switch)
                .help("Prefer separate scrcpy-backed windows for app launches and connected devices.")

                HStack(spacing: 10) {
                    Button("Show Android Window") {
                        model.revealAndroidWindow()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.runtimeReady || !model.settings.showAndroidWindow)
                    .help("Bring the full Android runtime window to the front when emulator-window mode is enabled.")

                    if model.runtimeState == .running || model.runtimeState == .starting {
                        Text("Restart the runtime after changing Android window visibility.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                statusStrip(
                    label: "Runtime status",
                    value: model.statusMessage,
                    tint: statusColor
                )

                statusStrip(
                    label: "Managed data root",
                    value: AppSettings.applicationSupportDirectory.path,
                    tint: Color(red: 0.54, green: 0.62, blue: 0.95)
                )

                if model.isProvisioningRuntime {
                    Text("Runtime setup is running in the background. Detailed installer output is written to `runtime-setup.log` inside the managed Logs folder.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Device Views")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))

                        Spacer()

                        Button("Refresh Devices") {
                            model.refreshAttachedDevices()
                        }
                        .buttonStyle(.bordered)
                        .help("Refresh the list of ADB-visible phones and emulator sessions.")
                    }

                    if model.attachedDevices.isEmpty {
                        Text("No ADB-visible Android devices are connected right now.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.attachedDevices) { device in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.title)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))

                                    Text(device.serial)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(device.kind == .physical ? "Phone" : "Runtime")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.06), in: Capsule())

                                Button(device.kind == .physical ? "View Screen" : "Open View") {
                                    model.openAttachedDevice(device)
                                }
                                .buttonStyle(.bordered)
                                .help(device.kind == .physical ? "Open this Android phone in a scrcpy viewer window." : "Open this runtime or emulator in a scrcpy viewer window.")
                            }
                        }
                    }
                }
            }
        }
    }

    private var behaviorCard: some View {
        card(title: "Background Mode", subtitle: "Turn the app into a utility: menu bar only, optional login item, and manual dashboard hiding when you are done configuring it.") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Run as a menu bar app", isOn: Binding(
                    get: { model.settings.menuBarOnly },
                    set: { model.toggleMenuBarOnly($0) }
                ))
                .toggleStyle(.switch)
                .help("Keep macOSdroid running from the menu bar so the dashboard can stay hidden.")

                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.toggleLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .help("Register the packaged app as a login item when supported by macOS.")

                HStack(spacing: 10) {
                    Button("Hide Dashboard") {
                        model.hideDashboard()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.settings.menuBarOnly)
                    .help("Hide the main window while leaving the menu bar utility running.")

                    Text(model.launchAtLoginStatus)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var folderCard: some View {
        card(title: "Inbox", subtitle: "Import APKs directly, drag them onto this card, or drop them into the watched folder from Finder.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("Watch folder", text: $watchFolderDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        applyWatchFolderDraft()
                    }
                    .help("Folder that macOSdroid watches for APK imports.")

                    Button("Browse") {
                        model.chooseWatchFolder()
                    }
                    .buttonStyle(.bordered)
                    .help("Choose a different inbox folder for APK files.")

                    Button("Apply") {
                        applyWatchFolderDraft()
                    }
                    .buttonStyle(.bordered)
                    .disabled(trimmedWatchFolderDraft.isEmpty)
                    .help("Save the current inbox path and restart folder watching if needed.")

                    Button("Open Folder") {
                        applyWatchFolderDraft()
                        model.revealWatchFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.29, green: 0.77, blue: 0.66))
                    .disabled(trimmedWatchFolderDraft.isEmpty)
                    .help("Reveal the current inbox folder in Finder.")

                    Button("Import APKs") {
                        applyWatchFolderDraft()
                        model.importAPKFiles()
                    }
                    .buttonStyle(.bordered)
                    .help("Copy one or more APK files into the inbox.")

                    Button("Rescan") {
                        applyWatchFolderDraft()
                        model.refreshLibrary()
                    }
                    .buttonStyle(.bordered)
                    .disabled(trimmedWatchFolderDraft.isEmpty)
                    .help("Reload the inbox catalog and refresh APK metadata.")
                }

                Toggle("Launch installed apps after successful install", isOn: Binding(
                    get: { model.settings.autoLaunchAfterInstall },
                    set: { model.toggleAutoLaunch($0) }
                ))
                .toggleStyle(.switch)
                .help("Automatically open an APK after it installs successfully.")

                statusStrip(
                    label: "Default inbox",
                    value: AppSettings.defaultWatchFolder.path,
                    tint: Color(red: 0.54, green: 0.62, blue: 0.95)
                )
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isInboxDropTargeted, perform: importDroppedFiles(from:))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    isInboxDropTargeted ? Color(red: 0.29, green: 0.77, blue: 0.66) : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [10, 8])
                )
        }
        .overlay(alignment: .center) {
            if isInboxDropTargeted {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Import APKs Into Inbox")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private var launcherCard: some View {
        card(title: "Finder Launchers", subtitle: "Generate `.webloc` launchers that wake macOSdroid through its custom URL scheme and open a specific Android app.") {
            VStack(alignment: .leading, spacing: 14) {
                statusStrip(
                    label: "Launchers folder",
                    value: AppSettings.defaultLauncherFolder.path,
                    tint: Color(red: 0.87, green: 0.46, blue: 0.28)
                )

                HStack(spacing: 10) {
                    Button("Export All Launchers") {
                        model.exportAllLaunchers()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.87, green: 0.46, blue: 0.28))
                    .disabled(model.folderApps.allSatisfy { $0.packageName == nil })
                    .help("Generate Finder launchers for every APK that has a resolved package name.")

                    Button("Open Launchers Folder") {
                        model.revealLauncherFolder()
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal the folder that stores exported Finder launchers.")
                }
            }
        }
    }

    private var documentationCard: some View {
        card(title: "Documentation And Credits", subtitle: "The repository and packaged app include install notes, release history, license texts, and upstream attribution for every required third-party dependency.") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Review the bundled documentation before redistributing a build, and use the upstream links below when you need the original license terms for required external tools.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 10) {
                    Link(destination: ProjectLinks.androidSDKTerms) {
                        Label("Android SDK Terms", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.29, green: 0.77, blue: 0.66))
                    .help("Open the Android SDK terms that govern the separately installed Google tools.")

                    Link(destination: ProjectLinks.openJDKLicense) {
                        Label("OpenJDK License", systemImage: "scroll")
                    }
                    .buttonStyle(.bordered)
                    .help("Open the OpenJDK GPLv2 plus Classpath Exception license text.")

                    Link(destination: ProjectLinks.scrcpyProject) {
                        Label("scrcpy Project", systemImage: "display")
                    }
                    .buttonStyle(.bordered)
                    .help("Open the upstream scrcpy project used for app windows and attached-device viewing.")

                    Link(destination: ProjectLinks.swiftLicense) {
                        Label("Swift License", systemImage: "shippingbox")
                    }
                    .buttonStyle(.bordered)
                    .help("Open the Swift project license and notices.")
                }

                HStack(spacing: 10) {
                    Link(destination: ProjectLinks.buyMeACoffee) {
                        Label("Buy Me a Coffee", systemImage: "cup.and.saucer")
                    }
                    .buttonStyle(.bordered)
                    .help("Open the project support page.")
                }

                Text("Packaged releases copy `README.md`, `CHANGELOG.md`, `DEPENDENCIES.md`, `THIRD_PARTY_NOTICES.md`, and `LICENSE` into the app bundle so compliance notes travel with the binary.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var libraryCard: some View {
        card(title: "App Library", subtitle: "Every APK in the inbox is cataloged here so you can reinstall, launch, uninstall, or export a Finder shortcut on demand.") {
            VStack(alignment: .leading, spacing: 12) {
                if model.folderApps.isEmpty {
                    emptyState(
                        icon: "shippingbox",
                        title: "No APKs in the inbox",
                        message: "Import APKs from the dashboard or drop them into the watched folder to populate the library."
                    )
                } else {
                    HStack(spacing: 10) {
                        TextField("Filter by app, package, or file name", text: $libraryFilter)
                            .textFieldStyle(.roundedBorder)
                            .help("Filter the APK library by display name, package name, or file name.")

                        if !libraryFilter.isEmpty {
                            Button("Clear") {
                                libraryFilter = ""
                            }
                            .buttonStyle(.bordered)
                            .help("Clear the current library filter.")
                        }

                        Spacer()

                        Text("\(filteredFolderApps.count) shown")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    if !model.runtimeReady {
                        Text("Start the runtime to confirm install state and enable launch or uninstall actions.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    if filteredFolderApps.isEmpty {
                        emptyState(
                            icon: "line.3.horizontal.decrease.circle",
                            title: "No matching APKs",
                            message: "Clear the filter or import a different APK to expand the library."
                        )
                    } else {
                        ForEach(filteredFolderApps) { app in
                            HStack(alignment: .center, spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(installBadgeColor(for: app.installState).opacity(0.16))

                                    Image(systemName: "app.badge")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(installBadgeColor(for: app.installState))
                                }
                                .frame(width: 54, height: 54)

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(app.displayName)
                                            .font(.system(size: 15, weight: .semibold, design: .rounded))

                                        Text(app.installState.title)
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(installBadgeColor(for: app.installState).opacity(0.18), in: Capsule())
                                            .foregroundStyle(installBadgeColor(for: app.installState))
                                    }

                                    Text(app.packageName ?? app.fileName)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 10) {
                                        Text(app.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                        Text(ByteCountFormatter.string(fromByteCount: app.fileSize, countStyle: .file))
                                    }
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                }

                                Spacer(minLength: 14)

                                HStack(spacing: 8) {
                                    Button(app.installState == .installed ? "Reinstall" : "Install") {
                                        model.installFolderApp(app)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color(red: 0.29, green: 0.77, blue: 0.66))
                                    .disabled(!model.runtimeReady)
                                    .help(app.installState == .installed ? "Reinstall this APK into the running Android runtime." : "Install this APK into the running Android runtime.")

                                    Button("Open") {
                                        model.launchFolderApp(app)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!canOpen(app))
                                    .help("Launch this installed Android app.")

                                    Button("Uninstall") {
                                        model.uninstallFolderApp(app)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!canUninstall(app))
                                    .help("Remove this app from the running Android runtime.")

                                    Button("Launcher") {
                                        model.exportLauncher(for: app)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(app.packageName == nil)
                                    .help("Export a Finder launcher that opens this Android app through macOSdroid.")
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(Color.black.opacity(0.04))
                            )
                        }
                    }
                }
            }
        }
    }

    private func card<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))

                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 18, y: 12)
    }

    private func heroChip(title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private func metricTile(title: String, value: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.68))
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statusStrip(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))

            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var statusColor: Color {
        switch model.runtimeState {
        case .stopped:
            .gray
        case .starting, .stopping:
            Color(red: 0.93, green: 0.78, blue: 0.43)
        case .running:
            Color(red: 0.29, green: 0.77, blue: 0.66)
        case .failed:
            Color(red: 0.87, green: 0.34, blue: 0.34)
        }
    }

    private var runtimeIcon: String {
        switch model.runtimeState {
        case .stopped:
            "pause.circle"
        case .starting:
            "bolt.circle"
        case .running:
            "play.circle"
        case .stopping:
            "stop.circle"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    private var watchFolderName: String {
        let name = model.watchFolderURL.lastPathComponent
        return name.isEmpty ? "Inbox" : name
    }

    private var trimmedWatchFolderDraft: String {
        watchFolderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The library can grow quickly in a shared inbox, so keep the filter local to the dashboard
    /// and match against the three identifiers a user typically recognizes.
    private var filteredFolderApps: [FolderApp] {
        let query = libraryFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return model.folderApps
        }

        let normalizedQuery = query.localizedLowercase
        return model.folderApps.filter { app in
            app.displayName.localizedLowercase.contains(normalizedQuery)
                || app.fileName.localizedLowercase.contains(normalizedQuery)
                || (app.packageName?.localizedLowercase.contains(normalizedQuery) ?? false)
        }
    }

    private func canOpen(_ app: FolderApp) -> Bool {
        model.runtimeReady && app.packageName != nil && app.installState == .installed
    }

    private func canUninstall(_ app: FolderApp) -> Bool {
        model.runtimeReady && app.packageName != nil && app.installState == .installed
    }

    private func installBadgeColor(for state: FolderAppInstallState) -> Color {
        switch state {
        case .unknown:
            .gray
        case .notInstalled:
            Color(red: 0.93, green: 0.78, blue: 0.43)
        case .installed:
            Color(red: 0.29, green: 0.77, blue: 0.66)
        }
    }

    private func syncWatchFolderDraft() {
        if watchFolderDraft != model.settings.watchFolderPath {
            watchFolderDraft = model.settings.watchFolderPath
        }
    }

    private func applyWatchFolderDraft() {
        guard !trimmedWatchFolderDraft.isEmpty else {
            return
        }

        let normalizedPath = NSString(string: trimmedWatchFolderDraft).expandingTildeInPath
        if normalizedPath != model.settings.watchFolderPath {
            model.updateWatchFolderPath(normalizedPath)
        }
        watchFolderDraft = normalizedPath
        model.applyWatchFolderSettings()
    }

    /// File URLs arrive from AppKit item providers as multiple bridged types; normalize them here
    /// before passing them back into the model's import pipeline.
    private func importDroppedFiles(from providers: [NSItemProvider]) -> Bool {
        let matchingProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matchingProviders.isEmpty else {
            return false
        }

        let appModel = model

        for provider in matchingProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.droppedFileURL(from: item), url.pathExtension.lowercased() == "apk" else {
                    return
                }

                DispatchQueue.main.async {
                    appModel.importAPKFiles(from: [url])
                }
            }
        }

        return true
    }

    nonisolated private static func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL:
            return url
        case let nsURL as NSURL:
            return nsURL as URL
        case let data as Data:
            return NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
        case let string as String:
            return URL(string: string)
        case let nsString as NSString:
            return URL(string: nsString as String)
        default:
            return nil
        }
    }
}
