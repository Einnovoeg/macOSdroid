import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

/// Coordinates the macOS host UI with the Android SDK toolchain, managed emulator lifecycle,
/// watched folder, and Finder launcher flow.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings.load()
    @Published var availableAVDs: [String] = []
    @Published var runtimeState: RuntimeState = .stopped
    @Published var statusMessage = "Waiting for configuration"
    @Published var logs: [LogEntry] = []
    @Published var connectedDevice: String?
    @Published var attachedDevices: [ADBDevice] = []
    @Published var folderApps: [FolderApp] = []
    @Published var launchAtLoginStatus = "Not configured"
    @Published var isProvisioningRuntime = false

    private var emulatorProcess: Process?
    private var folderMonitor: FolderMonitor?
    private var runtimeToolchain: AndroidToolchain?
    private var knownAPKs: [String: APKFingerprint] = [:]
    private var metadataCache: [String: APKMetadataCacheEntry] = [:]
    private var installedPackages = Set<String>()
    private var isScanningFolder = false
    private var rescanRequested = false
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private var provisionTask: Task<Void, Never>?
    private var pendingLaunchRequest: LaunchRequest?

    init() {
        migrateManagedFoldersIfNeeded()
        ensureManagedSupportFoldersExist()
        ensureWatchFolderExists()
        ensureLauncherFolderExists()

        Task {
            await bootstrap()
        }
    }

    // MARK: - Derived state

    var canStart: Bool {
        runtimeState == .stopped || runtimeState == .failed
    }

    var canStop: Bool {
        runtimeState == .running || runtimeState == .starting
    }

    var runtimeReady: Bool {
        runtimeState == .running && connectedDevice != nil && runtimeToolchain != nil
    }

    var watchFolderURL: URL {
        URL(fileURLWithPath: NSString(string: settings.watchFolderPath).expandingTildeInPath).standardizedFileURL
    }

    var launcherFolderURL: URL {
        AppSettings.defaultLauncherFolder.standardizedFileURL
    }

    var installedFolderAppCount: Int {
        folderApps.filter { $0.installState == .installed }.count
    }

    // MARK: - User actions

    func updateSDKPath(_ path: String) {
        settings.sdkRootPath = normalizedFilesystemPath(path)
        saveSettings()
    }

    func updateAVDName(_ name: String) {
        settings.avdName = name
        saveSettings()
    }

    func updateWatchFolderPath(_ path: String) {
        settings.watchFolderPath = normalizedFilesystemPath(path)
        saveSettings()
    }

    /// Keep watch-folder text edits cheap and reversible. Directory creation, folder monitoring,
    /// and optional rescans are triggered only when the caller explicitly applies the new path.
    func applyWatchFolderSettings(rescanReason: String? = nil) {
        ensureWatchFolderExists()
        restartFolderMonitor()

        Task {
            await refreshFolderCatalog()
            if let rescanReason, runtimeState == .running {
                scheduleFolderScan(reason: rescanReason)
            }
        }
    }

    func toggleAutoLaunch(_ enabled: Bool) {
        settings.autoLaunchAfterInstall = enabled
        saveSettings()
    }

    func toggleAutoStart(_ enabled: Bool) {
        settings.autoStartRuntime = enabled
        saveSettings()
    }

    func toggleMenuBarOnly(_ enabled: Bool) {
        settings.menuBarOnly = enabled
        saveSettings()
        applyPresentationMode()
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
        saveSettings()

        Task {
            await syncLaunchAtLogin()
        }
    }

    func toggleShowAndroidWindow(_ enabled: Bool) {
        settings.showAndroidWindow = enabled
        saveSettings()

        guard runtimeState == .running || runtimeState == .starting else {
            return
        }

        let mode = enabled ? "visible" : "hidden"
        statusMessage = "Restart the runtime to apply the \(mode) Android window mode"
        appendLog("Android window mode changed to \(mode); restart the runtime to apply it")
    }

    func togglePreferSeparateAppWindows(_ enabled: Bool) {
        settings.preferSeparateAppWindows = enabled
        saveSettings()

        statusMessage = enabled
            ? "Android apps will open in their own windows when scrcpy is available"
            : "Android apps will launch directly inside the runtime display"
    }

    func revealAndroidWindow() {
        guard runtimeState == .running else {
            statusMessage = "Start the runtime before opening the Android window"
            appendLog("Android window request skipped because the runtime is not running")
            return
        }

        guard settings.showAndroidWindow else {
            statusMessage = "Enable Show Android Window and restart the runtime to surface launched apps"
            appendLog("Android window request skipped because the runtime is configured to stay hidden")
            return
        }

        guard focusAndroidWindow() else {
            statusMessage = "Unable to bring the Android window to the front"
            appendLog("Android window activation failed")
            return
        }

        statusMessage = "Android window ready"
        appendLog("Brought the Android window to the front")
    }

    func clearLogs() {
        logs.removeAll()
        try? Data().write(to: AppSettings.activityLogFile, options: .atomic)
        statusMessage = "Activity log cleared"
    }

    func revealActivityLogFile() {
        ensureManagedSupportFoldersExist()
        if !FileManager.default.fileExists(atPath: AppSettings.activityLogFile.path) {
            FileManager.default.createFile(atPath: AppSettings.activityLogFile.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.activityLogFile])
    }

    func revealApplicationSupportFolder() {
        ensureManagedSupportFoldersExist()
        NSWorkspace.shared.open(AppSettings.applicationSupportDirectory)
    }

    func provisionManagedRuntime() {
        guard !isProvisioningRuntime else {
            return
        }

        provisionTask?.cancel()
        provisionTask = Task {
            await performProvisionManagedRuntime()
        }
    }

    func refreshAttachedDevices() {
        Task {
            await refreshADBDevices()
        }
    }

    func openAttachedDevice(_ device: ADBDevice) {
        do {
            try launchScrcpyWindow(for: device)
            statusMessage = "Opened \(device.title) in a device window"
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Device view failed for \(device.title): \(error.localizedDescription)")
        }
    }

    func chooseSDKFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select SDK"
        panel.message = "Choose the Android SDK root folder."

        if panel.runModal() == .OK, let url = panel.url {
            updateSDKPath(url.path)
            Task {
                await refreshAVDs()
            }
        }
    }

    func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Choose the folder macOSdroid should watch for APK files."

        if panel.runModal() == .OK, let url = panel.url {
            updateWatchFolderPath(url.path)
            applyWatchFolderSettings()
        }
    }

    func importAPKFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "apk")].compactMap { $0 }
        panel.prompt = "Import APKs"
        panel.message = "Choose one or more APK files to copy into the watched folder."

        if panel.runModal() == .OK {
            importAPKFiles(from: panel.urls)
        }
    }

    func importAPKFiles(from urls: [URL]) {
        Task {
            await performImportAPKFiles(from: urls)
        }
    }

    func revealWatchFolder() {
        applyWatchFolderSettings()
        NSWorkspace.shared.open(watchFolderURL)
    }

    func revealLauncherFolder() {
        ensureLauncherFolderExists()
        NSWorkspace.shared.open(launcherFolderURL)
    }

    func hideDashboard() {
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    func refreshLibrary() {
        applyWatchFolderSettings(rescanReason: "Manual rescan")
    }

    func installFolderApp(_ app: FolderApp) {
        Task {
            await performManualInstall(for: app)
        }
    }

    func launchFolderApp(_ app: FolderApp) {
        Task {
            await performManualLaunch(for: app)
        }
    }

    func uninstallFolderApp(_ app: FolderApp) {
        Task {
            await performManualUninstall(for: app)
        }
    }

    func exportLauncher(for app: FolderApp) {
        Task {
            await performExportLauncher(for: app)
        }
    }

    func exportAllLaunchers() {
        Task {
            await performExportAllLaunchers()
        }
    }

    func handleIncomingURL(_ url: URL) {
        Task {
            await processIncomingURL(url)
        }
    }

    func refreshAVDs() async {
        guard let toolchain = AndroidToolchain.resolve(preferredPath: settings.sdkRootPath) else {
            availableAVDs = []
            statusMessage = "Install or select an Android SDK to continue"
            return
        }

        runtimeToolchain = toolchain

        do {
            let output = try await Shell.run(
                executable: toolchain.emulator.path,
                arguments: ["-list-avds"],
                environment: toolchain.environment,
                timeout: 20
            )

            let avds = output.stdout
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            availableAVDs = avds
            if settings.avdName.isEmpty, let first = avds.first {
                settings.avdName = first
                saveSettings()
            }

            if runtimeState == .stopped || runtimeState == .failed {
                statusMessage = avds.isEmpty
                    ? "Create an Android Virtual Device in Android Studio or with avdmanager"
                    : "Ready to start the Android runtime"
            }
        } catch {
            availableAVDs = []
            statusMessage = "Unable to list Android Virtual Devices"
            appendLog("AVD discovery failed: \(error.localizedDescription)")
        }
    }

    func startRuntime() {
        guard canStart else {
            return
        }

        startTask?.cancel()
        startTask = Task {
            await performStart()
        }
    }

    func stopRuntime() {
        guard canStop else {
            return
        }

        stopTask?.cancel()
        stopTask = Task {
            await performStop()
        }
    }

    // MARK: - Bootstrapping and runtime lifecycle

    private func bootstrap() async {
        if settings.sdkRootPath.isEmpty, let detected = AndroidToolchain.resolve(preferredPath: "") {
            settings.sdkRootPath = detected.sdkRoot.path
            saveSettings()
        }

        applyPresentationMode()
        if settings.launchAtLogin {
            await syncLaunchAtLogin()
        } else {
            await syncLaunchAtLoginStatus()
        }
        restartFolderMonitor()
        await refreshAVDs()
        await refreshADBDevices()
        await refreshFolderCatalog()

        if settings.autoStartRuntime {
            startRuntime()
        }
    }

    /// Runs the packaged bootstrap script so drag-installed builds can provision their managed
    /// runtime without requiring the user to clone the repository first.
    private func performProvisionManagedRuntime() async {
        guard runtimeState == .stopped || runtimeState == .failed else {
            statusMessage = "Stop the runtime before running managed setup"
            appendLog("Managed runtime setup skipped because the runtime is active")
            return
        }

        guard let scriptURL = runtimeProvisionerScriptURL() else {
            statusMessage = RuntimeError.runtimeProvisioningUnavailable.localizedDescription
            appendLog(statusMessage)
            return
        }

        isProvisioningRuntime = true
        statusMessage = "Preparing the managed Android runtime"
        appendLog("Starting managed runtime setup")

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? AppSettings.defaultBundleIdentifier

        do {
            let exitStatus = try await runLoggedProcess(
                executable: "/bin/zsh",
                arguments: [scriptURL.path],
                environment: ["MACOSDROID_APP_DOMAIN": bundleIdentifier],
                logFile: AppSettings.runtimeSetupLogFile
            )

            guard exitStatus == 0 else {
                throw RuntimeError.runtimeProvisioningFailed(
                    "See \(AppSettings.runtimeSetupLogFile.lastPathComponent) for details."
                )
            }

            settings = AppSettings.load()
            ensureManagedSupportFoldersExist()
            ensureWatchFolderExists()
            ensureLauncherFolderExists()
            restartFolderMonitor()
            await refreshAVDs()
            await refreshADBDevices()
            await refreshFolderCatalog()

            appendLog("Managed runtime setup completed")
            appendLog("Detailed setup log written to \(AppSettings.runtimeSetupLogFile.path)")

            statusMessage = availableAVDs.isEmpty
                ? "Runtime setup completed. Create or detect an AVD, then start the runtime."
                : "Managed runtime ready"

            if settings.autoStartRuntime, canStart {
                startRuntime()
            }
        } catch {
            let errorDescription = error.localizedDescription
            statusMessage = errorDescription
            appendLog("Managed runtime setup failed: \(errorDescription)")
            appendLog("Detailed setup log written to \(AppSettings.runtimeSetupLogFile.path)")
        }

        isProvisioningRuntime = false
    }

    /// Launches a managed emulator, waits for Android services to come online, then starts folder
    /// scanning and periodic health checks.
    private func performStart() async {
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        runtimeState = .starting
        statusMessage = "Launching Android runtime"
        appendLog("Starting Android runtime")

        do {
            let toolchain = try resolveToolchain()
            runtimeToolchain = toolchain

            if settings.avdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw RuntimeError.avdMissing
            }

            ensureManagedSupportFoldersExist()
            ensureWatchFolderExists()

            let existingDevices = try await connectedDeviceSerials(using: toolchain)
            var emulatorArguments = [
                "-avd", settings.avdName,
                "-no-audio",
                "-no-boot-anim",
                "-no-snapshot-save",
                "-gpu", "swiftshader_indirect",
                "-netdelay", "none",
                "-netspeed", "full",
            ]

            if !settings.showAndroidWindow {
                emulatorArguments.insert("-no-window", at: 2)
            }

            let emulator = try Shell.spawn(
                executable: toolchain.emulator.path,
                arguments: emulatorArguments,
                environment: toolchain.environment
            )

            emulatorProcess = emulator
            appendLog("Emulator process launched for AVD \(settings.avdName)")

            appendLog("Waiting for an emulator device to appear in adb")
            let serial = try await waitForFreshDevice(using: toolchain, excluding: existingDevices)
            connectedDevice = serial
            appendLog("Device connected as \(serial)")

            appendLog("Waiting for Android boot completion on \(serial)")
            try await waitForBoot(using: toolchain, serial: serial)
            appendLog("Android runtime boot completed")

            restartFolderMonitor()
            knownAPKs.removeAll()
            runtimeState = .running
            statusMessage = launchReadyMessage()
            try await refreshInstalledPackages(using: toolchain, serial: serial)
            await refreshADBDevices(using: toolchain)
            startDeviceMonitor(using: toolchain, serial: serial)
            await fulfillPendingLaunchIfNeeded(using: toolchain, serial: serial)

            scheduleFolderScan(reason: "Initial scan")
        } catch {
            appendLog("Runtime start failed: \(error.localizedDescription)")
            await performStop(cleanStatus: false)
            runtimeState = .failed
            statusMessage = error.localizedDescription
        }
    }

    /// Stops the managed emulator and clears runtime-derived state without touching saved settings.
    private func performStop(cleanStatus: Bool = true) async {
        runtimeState = .stopping
        statusMessage = "Stopping Android runtime"
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil

        if
            let toolchain = runtimeToolchain,
            let serial = connectedDevice,
            !serial.isEmpty
        {
            _ = try? await Shell.run(
                executable: toolchain.adb.path,
                arguments: ["-s", serial, "emu", "kill"],
                environment: toolchain.environment
            )
        }

        if let emulatorProcess {
            if emulatorProcess.isRunning {
                emulatorProcess.terminate()
            }
            self.emulatorProcess = nil
        }

        connectedDevice = nil
        installedPackages.removeAll()
        knownAPKs.removeAll()
        await refreshADBDevices(using: runtimeToolchain ?? AndroidToolchain.resolve(preferredPath: settings.sdkRootPath))
        await refreshFolderCatalog()

        if cleanStatus {
            runtimeState = .stopped
            statusMessage = "Runtime stopped"
            appendLog("Android runtime stopped")
        }
    }

    private func resolveToolchain() throws -> AndroidToolchain {
        guard let toolchain = AndroidToolchain.resolve(preferredPath: settings.sdkRootPath) else {
            throw RuntimeError.sdkMissing
        }

        guard !settings.watchFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError.watchFolderMissing
        }

        return toolchain
    }

    private func launchReadyMessage() -> String {
        if settings.preferSeparateAppWindows, scrcpyExecutableURL() != nil {
            return "Watching \(watchFolderURL.lastPathComponent) and ready to open apps in their own windows"
        }

        if settings.preferSeparateAppWindows, !settings.showAndroidWindow {
            return "Watching \(watchFolderURL.lastPathComponent); install scrcpy or enable the Android window to surface apps"
        }

        if settings.showAndroidWindow {
            return "Watching \(watchFolderURL.lastPathComponent) and ready to open apps"
        }

        return "Watching \(watchFolderURL.lastPathComponent) in a hidden Android runtime"
    }

    /// The app only manages emulator devices, so physical phones are filtered out here.
    private func connectedDeviceSerials(using toolchain: AndroidToolchain) async throws -> Set<String> {
        let output = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["devices"],
            environment: toolchain.environment,
            timeout: 10
        )

        let serials = output.stdout
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> String? in
                let parts = String(line).split(separator: "\t")
                guard parts.count == 2, parts[1] == "device" else {
                    return nil
                }
                let serial = String(parts[0])
                return serial.hasPrefix("emulator-") ? serial : nil
            }

        return Set(serials)
    }

    /// Discover both emulator and physical devices so the UI can offer runtime and phone views
    /// through the same ADB-backed pipeline.
    private func refreshADBDevices(using toolchain: AndroidToolchain? = nil) async {
        let resolvedToolchain = toolchain ?? runtimeToolchain ?? AndroidToolchain.resolve(preferredPath: settings.sdkRootPath)
        guard let resolvedToolchain else {
            attachedDevices = []
            return
        }

        do {
            attachedDevices = try await adbDevices(using: resolvedToolchain)
        } catch {
            appendLog("ADB device refresh failed: \(error.localizedDescription)")
        }
    }

    private func adbDevices(using toolchain: AndroidToolchain) async throws -> [ADBDevice] {
        let output = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["devices", "-l"],
            environment: toolchain.environment,
            timeout: 10
        )

        guard output.status == 0 else {
            return []
        }

        return output.stdout
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return nil
                }

                let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count >= 2 else {
                    return nil
                }

                let serial = fields[0]
                let state = fields[1]
                guard state == "device" else {
                    return nil
                }

                let metadata = Dictionary(uniqueKeysWithValues: fields.dropFirst(2).compactMap { item -> (String, String)? in
                    guard let separator = item.firstIndex(of: ":") else {
                        return nil
                    }

                    let key = String(item[..<separator])
                    let value = String(item[item.index(after: separator)...])
                    return (key, value)
                })

                let isEmulator = serial.hasPrefix("emulator-")
                let displayName = metadata["model"]?.replacingOccurrences(of: "_", with: " ")
                    ?? metadata["device"]?.replacingOccurrences(of: "_", with: " ")
                    ?? serial

                return ADBDevice(
                    id: serial,
                    serial: serial,
                    name: displayName,
                    kind: isEmulator ? .emulator : .physical,
                    state: state
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .physical
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    private func waitForFreshDevice(
        using toolchain: AndroidToolchain,
        excluding existingDevices: Set<String>
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(180)

        while Date() < deadline {
            let current = try await connectedDeviceSerials(using: toolchain)
            if let fresh = current.subtracting(existingDevices).sorted().first {
                return fresh
            }

            try await Task.sleep(for: .seconds(2))
        }

        throw RuntimeError.noEmulatorDevice
    }

    /// Headless emulator boots are considered ready once either the canonical boot flag is set or
    /// Android's package manager responds after boot animation has stopped.
    private func waitForBoot(using toolchain: AndroidToolchain, serial: String) async throws {
        let deadline = Date().addingTimeInterval(240)

        while Date() < deadline {
            if try await isBootReady(using: toolchain, serial: serial) {
                return
            }

            try await Task.sleep(for: .seconds(2))
        }

        throw RuntimeError.emulatorBootTimedOut
    }

    private func isBootReady(using toolchain: AndroidToolchain, serial: String) async throws -> Bool {
        let bootCompleted = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["-s", serial, "shell", "getprop", "sys.boot_completed"],
            environment: toolchain.environment,
            timeout: 10
        )

        let bootAnimation = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["-s", serial, "shell", "getprop", "init.svc.bootanim"],
            environment: toolchain.environment,
            timeout: 10
        )

        guard bootAnimation.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "stopped" else {
            return false
        }

        let packageManager = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["-s", serial, "shell", "pm", "list", "packages"],
            environment: toolchain.environment,
            timeout: 20
        )

        let bootCompletedValue = bootCompleted.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if bootCompletedValue == "1" {
            return packageManager.status == 0
        }

        guard bootAnimation.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "stopped" else {
            return false
        }

        return packageManager.status == 0
    }

    // MARK: - Folder monitoring

    private func restartFolderMonitor() {
        folderMonitor?.stop()
        folderMonitor = nil

        let monitor = FolderMonitor(url: watchFolderURL) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                if self.runtimeState == .running {
                    self.scheduleFolderScan(reason: "Folder changed")
                } else {
                    await self.refreshFolderCatalog()
                }
            }
        }

        do {
            try monitor.start()
            folderMonitor = monitor
            appendLog("Watching \(watchFolderURL.path)")
        } catch {
            appendLog("Folder watch failed: \(error.localizedDescription)")
        }
    }

    private func applyPresentationMode() {
        let policy: NSApplication.ActivationPolicy = settings.menuBarOnly ? .accessory : .regular
        NSApp.setActivationPolicy(policy)

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            if self.settings.menuBarOnly {
                self.hideDashboard()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func syncLaunchAtLogin() async {
        do {
            if settings.launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }

            await syncLaunchAtLoginStatus()
        } catch {
            launchAtLoginStatus = "Unavailable: \(error.localizedDescription)"
            appendLog("Launch-at-login update failed: \(error.localizedDescription)")
        }
    }

    private func syncLaunchAtLoginStatus() async {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginStatus = "Enabled"
        case .requiresApproval:
            launchAtLoginStatus = "Waiting for approval in Login Items"
        case .notFound:
            launchAtLoginStatus = "Unavailable in development builds"
        case .notRegistered:
            launchAtLoginStatus = "Disabled"
        @unknown default:
            launchAtLoginStatus = "Unknown"
        }
    }

    private func scheduleFolderScan(reason: String) {
        guard runtimeState == .running else {
            return
        }

        if isScanningFolder {
            rescanRequested = true
            return
        }

        isScanningFolder = true

        Task {
            defer {
                isScanningFolder = false
                if rescanRequested {
                    rescanRequested = false
                    scheduleFolderScan(reason: "Queued rescan")
                }
            }

            appendLog(reason)
            await scanWatchFolder()
        }
    }

    /// Polling complements filesystem notifications so a missed write event does not strand a new
    /// APK in the inbox forever.
    private func startDeviceMonitor(using toolchain: AndroidToolchain, serial: String) {
        deviceMonitorTask?.cancel()
        deviceMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else {
                    return
                }

                await self.pollRuntime(using: toolchain, serial: serial)
            }
        }
    }

    private func pollRuntime(using toolchain: AndroidToolchain, serial: String) async {
        guard runtimeState == .running, connectedDevice == serial else {
            return
        }

        if let emulatorProcess, !emulatorProcess.isRunning {
            await handleRuntimeLoss(message: "The Android runtime exited unexpectedly")
            return
        }

        do {
            let devices = try await connectedDeviceSerials(using: toolchain)
            guard devices.contains(serial) else {
                await handleRuntimeLoss(message: "The Android runtime disconnected unexpectedly")
                return
            }

            try await refreshInstalledPackages(using: toolchain, serial: serial)
            await refreshADBDevices(using: toolchain)
            if hasPendingFolderChanges() {
                scheduleFolderScan(reason: "Background rescan")
            }
        } catch {
            appendLog("Runtime health check failed: \(error.localizedDescription)")
        }
    }

    private func handleRuntimeLoss(message: String) async {
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil

        if let emulatorProcess, emulatorProcess.isRunning {
            emulatorProcess.terminate()
        }

        self.emulatorProcess = nil
        connectedDevice = nil
        installedPackages.removeAll()
        knownAPKs.removeAll()
        runtimeState = .failed
        statusMessage = message
        appendLog(message)
        await refreshADBDevices(using: runtimeToolchain ?? AndroidToolchain.resolve(preferredPath: settings.sdkRootPath))
        await refreshFolderCatalog()
    }

    // MARK: - Library refresh and installation

    private func refreshFolderCatalog() async {
        let records = apkRecordsInWatchFolder()
        let toolchain = runtimeToolchain ?? AndroidToolchain.resolve(preferredPath: settings.sdkRootPath)
        var currentPaths = Set<String>()
        var apps: [FolderApp] = []

        for record in records {
            currentPaths.insert(record.url.path)
            let metadata = await metadata(for: record.url, fingerprint: record.fingerprint, using: toolchain)

            apps.append(FolderApp(
                id: record.url.path,
                fileURL: record.url,
                displayName: metadata.displayName,
                packageName: metadata.packageName,
                modifiedAt: record.fingerprint.modifiedAt,
                fileSize: record.fingerprint.fileSize,
                installState: installState(for: metadata.packageName)
            ))
        }

        metadataCache = metadataCache.filter { currentPaths.contains($0.key) }
        folderApps = apps
    }

    /// Reconciles the current inbox against the last processed fingerprints and reinstalls only the
    /// APKs that are new or have changed on disk.
    private func scanWatchFolder() async {
        guard
            runtimeState == .running,
            let toolchain = runtimeToolchain,
            let serial = connectedDevice
        else {
            return
        }

        var currentFiles = Set<String>()
        var installChanged = false

        for record in apkRecordsInWatchFolder() {
            let url = record.url
            currentFiles.insert(url.path)

            if knownAPKs[url.path] == record.fingerprint {
                continue
            }

            knownAPKs[url.path] = record.fingerprint

            do {
                try await installAPK(
                    at: url,
                    using: toolchain,
                    serial: serial,
                    launchAfterInstall: settings.autoLaunchAfterInstall
                )
                installChanged = true
            } catch {
                appendLog("Failed to process \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        knownAPKs = knownAPKs.filter { currentFiles.contains($0.key) }

        if installChanged {
            try? await refreshInstalledPackages(using: toolchain, serial: serial)
        } else {
            await refreshFolderCatalog()
        }
    }

    /// Installs an APK and optionally launches it immediately after a successful install.
    private func installAPK(
        at apkURL: URL,
        using toolchain: AndroidToolchain,
        serial: String,
        launchAfterInstall: Bool
    ) async throws {
        appendLog("Installing \(apkURL.lastPathComponent)")

        let maxAttempts = 2
        var finalOutput: ShellOutput?

        for attempt in 1...maxAttempts {
            let output = try await Shell.run(
                executable: toolchain.adb.path,
                arguments: ["-s", serial, "install", "-r", apkURL.path],
                environment: toolchain.environment,
                timeout: 180
            )
            finalOutput = output

            if output.status == 0, output.stdout.localizedCaseInsensitiveContains("success") {
                break
            }

            let message = [output.stderr, output.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")

            if attempt < maxAttempts, isTransientBootInstallFailure(message) {
                appendLog("Android is still finishing startup; retrying \(apkURL.lastPathComponent) install")
                try await Task.sleep(for: .seconds(12))
                continue
            }

            throw RuntimeError.installFailed(message.isEmpty ? "Unknown adb install error" : message)
        }

        guard let output = finalOutput,
              output.status == 0,
              output.stdout.localizedCaseInsensitiveContains("success") else {
            throw RuntimeError.installFailed("Unknown adb install error")
        }

        appendLog("Installed \(apkURL.lastPathComponent)")

        guard launchAfterInstall else {
            return
        }

        guard let packageName = try await packageName(for: apkURL, using: toolchain) else {
            appendLog("Installed \(apkURL.lastPathComponent) but could not infer its package name for auto-launch")
            return
        }

        try await launchPackageAfterInstall(
            named: packageName,
            displayName: apkURL.deletingPathExtension().lastPathComponent,
            using: toolchain,
            serial: serial
        )
    }

    private func isTransientBootInstallFailure(_ message: String) -> Bool {
        let normalized = message.localizedLowercase
        return normalized.contains("settings' before system providers are installed")
            || normalized.contains("before system providers are installed")
    }

    /// Package-name inference prefers `apkanalyzer`, but `aapt` remains a reliable fallback when
    /// only Android build-tools are installed.
    private func packageName(for apkURL: URL, using toolchain: AndroidToolchain) async throws -> String? {
        if let apkanalyzer = toolchain.apkanalyzer {
            let output = try? await Shell.run(
                executable: apkanalyzer.path,
                arguments: ["manifest", "application-id", apkURL.path],
                environment: toolchain.environment,
                timeout: 20
            )

            let packageName = output?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !packageName.isEmpty {
                return packageName
            }
        }

        if let aapt = toolchain.aapt {
            let output = try await Shell.run(
                executable: aapt.path,
                arguments: ["dump", "badging", apkURL.path],
                environment: toolchain.environment,
                timeout: 20
            )

            if let line = output.stdout.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("package:") }),
               let range = line.range(of: "name='")
            {
                let suffix = line[range.upperBound...]
                if let end = suffix.firstIndex(of: "'") {
                    return String(suffix[..<end])
                }
            }
        }

        return nil
    }

    private func performManualInstall(for app: FolderApp) async {
        guard
            runtimeState == .running,
            let toolchain = runtimeToolchain,
            let serial = connectedDevice
        else {
            statusMessage = "Start the runtime before installing apps"
            appendLog("Manual install skipped because the runtime is not running")
            return
        }

        do {
            try await installAPK(
                at: app.fileURL,
                using: toolchain,
                serial: serial,
                launchAfterInstall: settings.autoLaunchAfterInstall
            )
            if let fingerprint = fingerprint(for: app.fileURL) {
                knownAPKs[app.fileURL.path] = fingerprint
            }
            try? await refreshInstalledPackages(using: toolchain, serial: serial)
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Manual install failed for \(app.fileName): \(error.localizedDescription)")
        }
    }

    /// Importing normalizes all external APKs into the watch folder so the app can reuse the same
    /// install, launcher, and metadata pipeline everywhere else.
    private func performImportAPKFiles(from urls: [URL]) async {
        ensureWatchFolderExists()

        let uniqueAPKURLs = Array(Set(urls.map { $0.standardizedFileURL.path }))
            .map { URL(fileURLWithPath: $0) }
            .filter { $0.pathExtension.lowercased() == "apk" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !uniqueAPKURLs.isEmpty else {
            appendLog("Import skipped because no APK files were provided")
            return
        }

        var importedCount = 0

        for url in uniqueAPKURLs {
            let destinationURL = watchFolderURL.appendingPathComponent(url.lastPathComponent)
            let accessedSecurityScope = url.startAccessingSecurityScopedResource()

            do {
                if url.standardizedFileURL != destinationURL.standardizedFileURL {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }

                    try FileManager.default.copyItem(at: url, to: destinationURL)
                }

                importedCount += 1
                appendLog("Imported \(destinationURL.lastPathComponent)")
            } catch {
                appendLog("Import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }

            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        await refreshFolderCatalog()

        guard importedCount > 0 else {
            return
        }

        if runtimeState == .running {
            scheduleFolderScan(reason: "Imported APKs")
        } else {
            appendLog("Imported \(importedCount) APK(s) into \(watchFolderURL.lastPathComponent)")
        }
    }

    // MARK: - Launching and uninstalling apps

    private func performManualLaunch(for app: FolderApp) async {
        guard
            runtimeState == .running,
            let toolchain = runtimeToolchain,
            let serial = connectedDevice
        else {
            statusMessage = "Start the runtime before launching apps"
            appendLog("Manual launch skipped because the runtime is not running")
            return
        }

        do {
            let packageName = try await packageName(for: app.fileURL, using: toolchain) ?? app.packageName
            guard let packageName else {
                statusMessage = "Unable to infer the app package name"
                appendLog("Launch skipped for \(app.fileName) because its package name is unknown")
                return
            }

            try await launchPackage(
                named: packageName,
                displayName: app.displayName,
                using: toolchain,
                serial: serial
            )
            statusMessage = statusMessageForLaunch(of: app.displayName, packageName: packageName)
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Manual launch failed for \(app.fileName): \(error.localizedDescription)")
        }
    }

    private func performManualUninstall(for app: FolderApp) async {
        guard
            runtimeState == .running,
            let toolchain = runtimeToolchain,
            let serial = connectedDevice
        else {
            statusMessage = "Start the runtime before uninstalling apps"
            appendLog("Manual uninstall skipped because the runtime is not running")
            return
        }

        guard let packageName = app.packageName else {
            statusMessage = "Unable to infer the app package name"
            appendLog("Uninstall skipped for \(app.fileName) because its package name is unknown")
            return
        }

        do {
            try await uninstallPackage(named: packageName, using: toolchain, serial: serial)
            try? await refreshInstalledPackages(using: toolchain, serial: serial)
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Manual uninstall failed for \(app.fileName): \(error.localizedDescription)")
        }
    }

    private func performExportLauncher(for app: FolderApp) async {
        guard let packageName = app.packageName else {
            appendLog("Launcher export skipped for \(app.fileName) because its package name is unknown")
            return
        }

        do {
            try writeLauncher(for: LaunchRequest(packageName: packageName, displayName: app.displayName))
            appendLog("Created launcher for \(app.displayName)")
        } catch {
            appendLog("Launcher export failed for \(app.displayName): \(error.localizedDescription)")
        }
    }

    private func performExportAllLaunchers() async {
        let exportableApps = folderApps.filter { $0.packageName != nil }
        guard !exportableApps.isEmpty else {
            appendLog("No launchers exported because the library does not contain any package-aware APKs")
            return
        }

        var createdCount = 0

        for app in exportableApps {
            guard let packageName = app.packageName else {
                continue
            }

            do {
                try writeLauncher(for: LaunchRequest(packageName: packageName, displayName: app.displayName))
                createdCount += 1
            } catch {
                appendLog("Launcher export failed for \(app.displayName): \(error.localizedDescription)")
            }
        }

        appendLog("Exported \(createdCount) launcher(s) to \(launcherFolderURL.lastPathComponent)")
    }

    /// Opens a package in a dedicated scrcpy window when available, otherwise falls back to the
    /// Android runtime display managed by the emulator itself.
    private func launchPackage(
        named packageName: String,
        displayName: String? = nil,
        using toolchain: AndroidToolchain,
        serial: String
    ) async throws {
        let launchTitle = displayName ?? packageName
        let prefersSeparateWindow = settings.preferSeparateAppWindows
        var openedSeparateWindow = false

        if settings.preferSeparateAppWindows {
            do {
                try launchScrcpyWindow(
                    for: ADBDevice(
                        id: serial,
                        serial: serial,
                        name: launchTitle,
                        kind: .emulator,
                        state: "device"
                    )
                )
                openedSeparateWindow = true
            } catch {
                if settings.showAndroidWindow {
                    appendLog("Separate app window fallback for \(launchTitle): \(error.localizedDescription)")
                } else {
                    throw error
                }
            }
        }

        if let componentName = try await launchComponent(for: packageName, using: toolchain, serial: serial) {
            let launch = try await Shell.run(
                executable: toolchain.adb.path,
                arguments: [
                    "-s", serial,
                    "shell",
                    "am",
                    "start",
                    "-n", componentName,
                ],
                environment: toolchain.environment,
                timeout: 30
            )

            guard launch.status == 0 else {
                let message = [launch.stderr, launch.stdout]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                throw RuntimeError.launchFailed(message.isEmpty ? componentName : message)
            }

            if settings.showAndroidWindow && !openedSeparateWindow {
                if focusAndroidWindow() {
                    appendLog("Brought the Android window to the front")
                } else {
                    appendLog("Launched \(componentName) but could not activate the Android window automatically")
                }
            }

            if prefersSeparateWindow && openedSeparateWindow {
                appendLog("Opened \(launchTitle) in its own window")
            }

            appendLog("Launched \(componentName)")
            return
        }

        let fallback = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: [
                "-s", serial,
                "shell",
                "monkey",
                "-p", packageName,
                "-c", "android.intent.category.LAUNCHER",
                "1",
            ],
            environment: toolchain.environment,
            timeout: 30
        )

        guard fallback.status == 0 else {
            let message = [fallback.stderr, fallback.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            throw RuntimeError.launchFailed(message.isEmpty ? packageName : message)
        }

        if settings.showAndroidWindow && !openedSeparateWindow {
            if focusAndroidWindow() {
                appendLog("Brought the Android window to the front")
            } else {
                appendLog("Launched \(packageName) but could not activate the Android window automatically")
            }
        }

        if prefersSeparateWindow && openedSeparateWindow {
            appendLog("Opened \(launchTitle) in its own window")
        }

        appendLog("Launched \(packageName)")
    }

    /// Newly installed packages can report a successful install before their launcher entry is
    /// queryable. Retry launch a few times so automatic post-install opens are reliable.
    private func launchPackageAfterInstall(
        named packageName: String,
        displayName: String? = nil,
        using toolchain: AndroidToolchain,
        serial: String
    ) async throws {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            do {
                try await launchPackage(
                    named: packageName,
                    displayName: displayName,
                    using: toolchain,
                    serial: serial
                )
                return
            } catch {
                guard attempt < maxAttempts else {
                    throw error
                }

                appendLog("Retrying launch for \(displayName ?? packageName) after install (\(attempt + 1)/\(maxAttempts))")
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Newly installed apps may not expose their launcher activity immediately, so resolve the
    /// component for a short retry window before using the broader fallback launcher.
    private func launchComponent(
        for packageName: String,
        using toolchain: AndroidToolchain,
        serial: String
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(15)

        while Date() < deadline {
            if let component = try await resolvedActivityComponent(
                for: packageName,
                using: toolchain,
                serial: serial
            ) {
                return component
            }

            if let component = try await queriedLauncherComponent(
                for: packageName,
                using: toolchain,
                serial: serial
            ) {
                return component
            }

            try await Task.sleep(for: .seconds(1))
        }

        return nil
    }

    private func resolvedActivityComponent(
        for packageName: String,
        using toolchain: AndroidToolchain,
        serial: String
    ) async throws -> String? {
        let output = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: [
                "-s", serial,
                "shell",
                "cmd",
                "package",
                "resolve-activity",
                "--brief",
                packageName,
            ],
            environment: toolchain.environment,
            timeout: 15
        )

        guard output.status == 0 else {
            return nil
        }

        let lines = output.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.last(where: { $0.contains("/") && $0.hasPrefix(packageName) })
    }

    private func queriedLauncherComponent(
        for packageName: String,
        using toolchain: AndroidToolchain,
        serial: String
    ) async throws -> String? {
        let output = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: [
                "-s", serial,
                "shell",
                "cmd",
                "package",
                "query-activities",
                "-a", "android.intent.action.MAIN",
                "-c", "android.intent.category.LAUNCHER",
                packageName,
            ],
            environment: toolchain.environment,
            timeout: 15
        )

        guard output.status == 0 else {
            return nil
        }

        let packageLine = output.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.hasPrefix("packageName=") })

        let activityLine = output.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.hasPrefix("name=") })

        guard
            let resolvedPackageLine = packageLine,
            let resolvedActivityLine = activityLine
        else {
            return nil
        }

        let resolvedPackageName = String(resolvedPackageLine.dropFirst("packageName=".count))
        let activityName = String(resolvedActivityLine.dropFirst("name=".count))

        guard resolvedPackageName == packageName else {
            return nil
        }

        if activityName.hasPrefix(".") {
            return "\(packageName)/\(activityName)"
        }

        return "\(packageName)/\(activityName)"
    }

    private func uninstallPackage(named packageName: String, using toolchain: AndroidToolchain, serial: String) async throws {
        let uninstall = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["-s", serial, "uninstall", packageName],
            environment: toolchain.environment,
            timeout: 30
        )

        guard uninstall.status == 0, uninstall.stdout.localizedCaseInsensitiveContains("success") else {
            let message = [uninstall.stderr, uninstall.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            throw RuntimeError.uninstallFailed(message.isEmpty ? packageName : message)
        }

        appendLog("Uninstalled \(packageName)")
    }

    // MARK: - Filesystem metadata and package state

    private func apkRecordsInWatchFolder() -> [(url: URL, fingerprint: APKFingerprint)] {
        let folderURL = watchFolderURL
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension.lowercased() == "apk" }
            .compactMap { url in
                guard
                    let values = try? url.resourceValues(forKeys: keys),
                    values.isRegularFile == true
                else {
                    return nil
                }

                return (
                    url: url,
                    fingerprint: APKFingerprint(
                        fileSize: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast
                    )
                )
            }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    private func fingerprint(for apkURL: URL) -> APKFingerprint? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let values = try? apkURL.resourceValues(forKeys: keys) else {
            return nil
        }

        return APKFingerprint(
            fileSize: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }

    private func hasPendingFolderChanges() -> Bool {
        let currentRecords = apkRecordsInWatchFolder()

        if currentRecords.count != knownAPKs.count {
            return true
        }

        for record in currentRecords {
            if knownAPKs[record.url.path] != record.fingerprint {
                return true
            }
        }

        return false
    }

    /// Refreshes `pm list packages` after installs, uninstalls, and health checks so the library
    /// reflects the runtime accurately without manual refreshes.
    private func refreshInstalledPackages(using toolchain: AndroidToolchain, serial: String) async throws {
        let output = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["-s", serial, "shell", "pm", "list", "packages"],
            environment: toolchain.environment,
            timeout: 20
        )

        guard output.status == 0 else {
            let message = [output.stderr, output.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            throw RuntimeError.launchFailed(message.isEmpty ? "Unable to read installed packages" : message)
        }

        let packages = Set(output.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.hasPrefix("package:") else {
                    return nil
                }
                return String(value.dropFirst("package:".count))
            })

        if packages != installedPackages {
            installedPackages = packages
            await refreshFolderCatalog()
        }
    }

    // MARK: - Finder launcher URL handling

    private func processIncomingURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "macosdroid" else {
            return
        }

        let host = url.host?.lowercased()
        let action = host ?? url.pathComponents.dropFirst().first?.lowercased()

        guard action == "launch" else {
            appendLog("Ignored unsupported URL action: \(url.absoluteString)")
            return
        }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let packageName = components.queryItems?.first(where: { $0.name == "package" })?.value,
            !packageName.isEmpty
        else {
            appendLog("Ignored malformed launcher URL: \(url.absoluteString)")
            return
        }

        guard isValidAndroidPackageName(packageName) else {
            let error = RuntimeError.invalidPackageName(packageName)
            statusMessage = error.localizedDescription
            appendLog("Rejected launcher request with invalid package name: \(packageName)")
            return
        }

        let displayName = components.queryItems?.first(where: { $0.name == "name" })?.value
        pendingLaunchRequest = LaunchRequest(packageName: packageName, displayName: displayName)
        appendLog("Received launcher request for \(displayName ?? packageName)")

        if
            runtimeState == .running,
            let toolchain = runtimeToolchain,
            let serial = connectedDevice
        {
            await fulfillPendingLaunchIfNeeded(using: toolchain, serial: serial)
            return
        }

        if canStart || runtimeState == .failed {
            startRuntime()
        } else {
            statusMessage = "Queued launch for \(displayName ?? packageName)"
        }
    }

    private func fulfillPendingLaunchIfNeeded(using toolchain: AndroidToolchain, serial: String) async {
        guard let request = pendingLaunchRequest else {
            return
        }

        do {
            if !installedPackages.contains(request.packageName) {
                await refreshFolderCatalog()

                guard let sourceApp = folderApps.first(where: { $0.packageName == request.packageName }) else {
                    statusMessage = "\(request.displayName ?? request.packageName) is not installed and no matching APK is in the watch folder"
                    appendLog(statusMessage)
                    pendingLaunchRequest = nil
                    return
                }

                appendLog("Installing \(sourceApp.displayName) for launcher request")
                try await installAPK(
                    at: sourceApp.fileURL,
                    using: toolchain,
                    serial: serial,
                    launchAfterInstall: false
                )
                try await refreshInstalledPackages(using: toolchain, serial: serial)
            }

            try await launchPackage(
                named: request.packageName,
                displayName: request.displayName,
                using: toolchain,
                serial: serial
            )
            statusMessage = statusMessageForLaunch(
                of: request.displayName,
                packageName: request.packageName
            )
            pendingLaunchRequest = nil
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Launcher request failed for \(request.displayName ?? request.packageName): \(error.localizedDescription)")
        }
    }

    // MARK: - APK metadata extraction

    private func installState(for packageName: String?) -> FolderAppInstallState {
        guard runtimeReady else {
            return .unknown
        }

        guard let packageName, !packageName.isEmpty else {
            return .unknown
        }

        return installedPackages.contains(packageName) ? .installed : .notInstalled
    }

    private func metadata(
        for apkURL: URL,
        fingerprint: APKFingerprint,
        using toolchain: AndroidToolchain?
    ) async -> APKMetadata {
        if let cached = metadataCache[apkURL.path], cached.fingerprint == fingerprint {
            return cached.metadata
        }

        var metadata = APKMetadata(
            displayName: apkURL.deletingPathExtension().lastPathComponent,
            packageName: nil
        )

        if let toolchain {
            if let badging = try? await badging(for: apkURL, using: toolchain) {
                if let label = applicationLabel(fromBadging: badging) {
                    metadata = APKMetadata(displayName: label, packageName: metadata.packageName)
                }

                if let packageName = packageName(fromBadging: badging) {
                    metadata = APKMetadata(displayName: metadata.displayName, packageName: packageName)
                }
            }

            if metadata.packageName == nil {
                let packageName = try? await packageName(for: apkURL, using: toolchain)
                metadata = APKMetadata(displayName: metadata.displayName, packageName: packageName ?? nil)
            }
        }

        metadataCache[apkURL.path] = APKMetadataCacheEntry(fingerprint: fingerprint, metadata: metadata)
        return metadata
    }

    private func badging(for apkURL: URL, using toolchain: AndroidToolchain) async throws -> String? {
        guard let aapt = toolchain.aapt else {
            return nil
        }

        let output = try await Shell.run(
            executable: aapt.path,
            arguments: ["dump", "badging", apkURL.path],
            environment: toolchain.environment,
            timeout: 20
        )

        return output.status == 0 ? output.stdout : nil
    }

    private func packageName(fromBadging badging: String) -> String? {
        guard let line = badging.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("package:") }),
              let range = line.range(of: "name='")
        else {
            return nil
        }

        let suffix = line[range.upperBound...]
        guard let end = suffix.firstIndex(of: "'") else {
            return nil
        }

        return String(suffix[..<end])
    }

    private func applicationLabel(fromBadging badging: String) -> String? {
        let lines = badging.split(whereSeparator: \.isNewline)

        if let defaultLabel = lines.first(where: { $0.hasPrefix("application-label:'") }) {
            return value(inBadgingLine: defaultLabel)
        }

        if let localizedLabel = lines.first(where: { $0.hasPrefix("application-label-") }) {
            return value(inBadgingLine: localizedLabel)
        }

        return nil
    }

    private func value(inBadgingLine line: Substring) -> String? {
        guard let firstQuote = line.firstIndex(of: "'") else {
            return nil
        }

        let suffix = line[line.index(after: firstQuote)...]
        guard let closingQuote = suffix.firstIndex(of: "'") else {
            return nil
        }

        return String(suffix[..<closingQuote])
    }

    // MARK: - Filesystem helpers and logging

    private func writeLauncher(for request: LaunchRequest) throws {
        guard isValidAndroidPackageName(request.packageName) else {
            throw RuntimeError.invalidPackageName(request.packageName)
        }

        ensureLauncherFolderExists()

        var components = URLComponents()
        components.scheme = "macosdroid"
        components.host = "launch"
        components.queryItems = [
            URLQueryItem(name: "package", value: request.packageName),
            URLQueryItem(name: "name", value: request.displayName),
        ]

        guard let urlString = components.url?.absoluteString else {
            throw CocoaError(.fileWriteUnknown)
        }

        let payload: [String: String] = ["URL": urlString]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let fileURL = launcherFolderURL.appendingPathComponent("\(safeFileName(for: request.displayName ?? request.packageName)).webloc")
        try data.write(to: fileURL, options: .atomic)
    }

    private func safeFileName(for value: String) -> String {
        let disallowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " .-_()"))
            .inverted
        let parts = value.components(separatedBy: disallowed).filter { !$0.isEmpty }
        let sanitized = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(sanitized.prefix(80))
        return trimmed.isEmpty ? "Android App" : trimmed
    }

    /// Package names travel through custom URL launches and `adb` commands, so keep them within
    /// the Android identifier grammar even though subprocesses are already launched without a
    /// shell.
    private func isValidAndroidPackageName(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func statusMessageForLaunch(of displayName: String?, packageName: String) -> String {
        let title = displayName ?? packageName

        if settings.preferSeparateAppWindows, scrcpyExecutableURL() != nil {
            return "Opened \(title) in its own window"
        }

        if settings.showAndroidWindow {
            return "Opened \(title) in the Android window"
        }

        return "Launched \(title) in the hidden Android runtime"
    }

    /// scrcpy is optional today so packaged builds can adopt it incrementally. Search the bundle
    /// first for future self-contained releases, then fall back to common user installs.
    private func scrcpyExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []

        if let override = environment["MACOSDROID_SCRCPY_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/scrcpy") {
            candidates.append(bundled)
        }

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/scrcpy"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/scrcpy"))

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func launchScrcpyWindow(for device: ADBDevice) throws {
        guard let scrcpy = scrcpyExecutableURL() else {
            throw RuntimeError.launchFailed(
                settings.showAndroidWindow
                    ? "scrcpy is not installed, so macOSdroid fell back to the Android runtime display."
                    : "scrcpy is not installed. Install scrcpy or enable Show Android Window."
            )
        }

        let arguments = [
            "-s", device.serial,
            "--window-title", safeFileName(for: device.title),
        ]

        _ = try Shell.spawn(executable: scrcpy.path, arguments: arguments)
        appendLog("Opened \(device.title) via scrcpy")
    }

    /// Prefer the packaged setup script so drag-installed builds remain self-service, then fall
    /// back to the repository script for source checkouts.
    private func runtimeProvisionerScriptURL() -> URL? {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("provision-runtime.sh", isDirectory: false)

        let repositoryScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("provision-runtime.sh", isDirectory: false)

        let candidates = [bundled, repositoryScript].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    /// Runtime setup can be long-running and verbose, so send the full transcript to a dedicated
    /// log file instead of spamming the main activity stream.
    private func runLoggedProcess(
        executable: String,
        arguments: [String],
        environment: [String: String],
        logFile: URL
    ) async throws -> Int32 {
        ensureManagedSupportFoldersExist()
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        guard let logHandle = try? FileHandle(forWritingTo: logFile) else {
            throw RuntimeError.runtimeProvisioningFailed("Unable to open \(logFile.lastPathComponent).")
        }

        _ = try? logHandle.seekToEnd()

        let header = """
        === \(Date().formatted(date: .abbreviated, time: .standard)) ===
        Command: \(([executable] + arguments).joined(separator: " "))

        """

        try? logHandle.write(contentsOf: Data(header.utf8))

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = logHandle
            process.standardError = logHandle

            var mergedEnvironment = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                mergedEnvironment[key] = value
            }
            process.environment = mergedEnvironment

            process.terminationHandler = { process in
                let footer = "\nExit status: \(process.terminationStatus)\n"
                try? logHandle.write(contentsOf: Data(footer.utf8))
                try? logHandle.close()
                continuation.resume(returning: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                try? logHandle.close()
                continuation.resume(throwing: error)
            }
        }
    }

    private func migrateManagedFoldersIfNeeded() {
        migrateFolderContentsIfNeeded(
            from: AppSettings.legacyDefaultWatchFolder,
            to: AppSettings.defaultWatchFolder,
            isManagedDestination: settings.watchFolderPath == AppSettings.defaultWatchFolder.path
        )
        migrateFolderContentsIfNeeded(
            from: AppSettings.legacyDefaultLauncherFolder,
            to: AppSettings.defaultLauncherFolder,
            isManagedDestination: true
        )
    }

    private func migrateFolderContentsIfNeeded(from legacyFolder: URL, to managedFolder: URL, isManagedDestination: Bool) {
        guard isManagedDestination, legacyFolder.standardizedFileURL != managedFolder.standardizedFileURL else {
            return
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyFolder.path) else {
            return
        }

        let legacyContents = (try? fileManager.contentsOfDirectory(at: legacyFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard !legacyContents.isEmpty else {
            return
        }

        do {
            try fileManager.createDirectory(at: managedFolder, withIntermediateDirectories: true)

            for sourceURL in legacyContents {
                let destinationURL = managedFolder.appendingPathComponent(sourceURL.lastPathComponent)
                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    continue
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            appendLog("Managed folder migration failed: \(error.localizedDescription)")
        }
    }

    private func ensureWatchFolderExists() {
        let folder = watchFolderURL

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            appendLog("Unable to create watch folder: \(error.localizedDescription)")
        }
    }

    /// Keep all generated runtime state inside the app-owned support tree so drag-installed builds
    /// do not depend on legacy folders like `~/Applications` or `~/.android`.
    private func ensureManagedSupportFoldersExist() {
        let folders = [
            AppSettings.applicationSupportDirectory,
            AppSettings.defaultManagedSDKRoot.deletingLastPathComponent(),
            AppSettings.logsDirectory,
            AppSettings.managedAndroidUserHome,
            AppSettings.managedAVDDirectory,
        ]

        for folder in folders {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                appendLog("Unable to prepare \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func ensureLauncherFolderExists() {
        do {
            try FileManager.default.createDirectory(at: launcherFolderURL, withIntermediateDirectories: true)
        } catch {
            appendLog("Unable to create launcher folder: \(error.localizedDescription)")
        }
    }

    private func saveSettings() {
        settings.save()
    }

    private func normalizedFilesystemPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).standardizedFileURL.path
    }

    @discardableResult
    private func focusAndroidWindow() -> Bool {
        guard settings.showAndroidWindow, let emulatorProcess else {
            return false
        }

        guard let runtimeApp = NSRunningApplication(processIdentifier: emulatorProcess.processIdentifier) else {
            return false
        }

        return runtimeApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func appendLog(_ message: String) {
        let entry = LogEntry(timestamp: Date(), message: message)
        logs.insert(entry, at: 0)
        appendLogToDisk(entry)

        if logs.count > 150 {
            logs.removeLast(logs.count - 150)
        }
    }

    private func appendLogToDisk(_ entry: LogEntry) {
        ensureManagedSupportFoldersExist()
        let line = "\(entry.timestamp.formatted(date: .abbreviated, time: .standard))  \(entry.message)\n"
        let data = Data(line.utf8)

        if !FileManager.default.fileExists(atPath: AppSettings.activityLogFile.path) {
            try? data.write(to: AppSettings.activityLogFile, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: AppSettings.activityLogFile) else {
            return
        }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }
}
