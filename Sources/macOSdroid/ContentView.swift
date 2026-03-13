import SwiftUI
import UniformTypeIdentifiers

/// Main dashboard shown when the app is not running in menu-bar-only mode.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isInboxDropTargeted = false

    private let summaryColumns = [
        GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 18, alignment: .top),
    ]

    var body: some View {
        ZStack {
            backgroundView

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard

                    LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 18) {
                        runtimeCard
                        behaviorCard
                        folderCard
                        launcherCard
                        supportCard
                    }

                    libraryCard
                    logsCard
                }
                .padding(24)
            }
        }
        .frame(minWidth: 920, minHeight: 720)
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

                    Text("A native macOS host for Android apps that keeps the emulator hidden, runs in the background, and installs APKs from a simple inbox.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)

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

                    Button("Stop Runtime") {
                        model.stopRuntime()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canStop)

                    Link(destination: ProjectLinks.support) {
                        Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.87, green: 0.46, blue: 0.28))

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

    private var runtimeCard: some View {
        card(title: "Runtime", subtitle: "Point the host at your Android SDK, select an AVD, then let macOSdroid keep that emulator out of sight.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("Android SDK path", text: Binding(
                        get: { model.settings.sdkRootPath },
                        set: { model.updateSDKPath($0) }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button("Browse") {
                        model.chooseSDKFolder()
                    }
                    .buttonStyle(.bordered)

                    Button("Refresh AVDs") {
                        Task {
                            await model.refreshAVDs()
                        }
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    if model.availableAVDs.isEmpty {
                        TextField("AVD name", text: Binding(
                            get: { model.settings.avdName },
                            set: { model.updateAVDName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
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
                    }

                    Toggle("Auto-start runtime on launch", isOn: Binding(
                        get: { model.settings.autoStartRuntime },
                        set: { model.toggleAutoStart($0) }
                    ))
                    .toggleStyle(.switch)
                }

                statusStrip(
                    label: "Runtime status",
                    value: model.statusMessage,
                    tint: statusColor
                )
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

                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.toggleLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)

                HStack(spacing: 10) {
                    Button("Hide Dashboard") {
                        model.hideDashboard()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.settings.menuBarOnly)

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
                    TextField("Watch folder", text: Binding(
                        get: { model.settings.watchFolderPath },
                        set: { model.updateWatchFolderPath($0) }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button("Browse") {
                        model.chooseWatchFolder()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Folder") {
                        model.revealWatchFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.29, green: 0.77, blue: 0.66))

                    Button("Import APKs") {
                        model.importAPKFiles()
                    }
                    .buttonStyle(.bordered)

                    Button("Rescan") {
                        model.refreshLibrary()
                    }
                    .buttonStyle(.bordered)
                }

                Toggle("Launch installed apps after successful install", isOn: Binding(
                    get: { model.settings.autoLaunchAfterInstall },
                    set: { model.toggleAutoLaunch($0) }
                ))
                .toggleStyle(.switch)

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

                    Button("Open Launchers Folder") {
                        model.revealLauncherFolder()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var supportCard: some View {
        card(title: "Support And Credits", subtitle: "Repository docs include setup instructions, dependency notes, third-party notices, and the open-source license for this project.") {
            VStack(alignment: .leading, spacing: 14) {
                Text("If this project saves you time, support future polish and maintenance through Buy Me a Coffee.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Link(destination: ProjectLinks.support) {
                        Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.87, green: 0.46, blue: 0.28))

                    Text("License and third-party credits ship with the repository.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
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
                    if !model.runtimeReady {
                        Text("Start the runtime to confirm install state and enable launch or uninstall actions.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.folderApps) { app in
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

                                Button("Open") {
                                    model.launchFolderApp(app)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!canOpen(app))

                                Button("Uninstall") {
                                    model.uninstallFolderApp(app)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!canUninstall(app))

                                Button("Launcher") {
                                    model.exportLauncher(for: app)
                                }
                                .buttonStyle(.bordered)
                                .disabled(app.packageName == nil)
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

    private var logsCard: some View {
        card(title: "Activity", subtitle: "Runtime events stay visible here so the app can operate quietly in the background without becoming opaque.") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.logs.isEmpty {
                        emptyState(
                            icon: "list.bullet.rectangle.portrait",
                            title: "No activity yet",
                            message: "Start the runtime or import an APK to begin populating the activity stream."
                        )
                    } else {
                        ForEach(model.logs) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 92, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(minHeight: 240)
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
