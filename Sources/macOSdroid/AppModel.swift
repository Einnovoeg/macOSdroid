import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

/// Coordinates the macOS host UI with the Android SDK toolchain, hidden emulator lifecycle,
/// watched folder, and Finder launcher flow.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings.load()
    @Published var availableAVDs: [String] = []
    @Published var runtimeState: RuntimeState = .stopped
    @Published var statusMessage = "Waiting for configuration"
    @Published var logs: [LogEntry] = []
    @Published var connectedDevice: String?
    @Published var folderApps: [FolderApp] = []
    @Published var launchAtLoginStatus = "Not configured"

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
    private var pendingLaunchRequest: LaunchRequest?

    init() {
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
        URL(fileURLWithPath: NSString(string: settings.watchFolderPath).expandingTildeInPath)
    }

    var launcherFolderURL: URL {
        AppSettings.defaultLauncherFolder
    }

    var installedFolderAppCount: Int {
        folderApps.filter { $0.installState == .installed }.count
    }

    // MARK: - User actions

    func updateSDKPath(_ path: String) {
        settings.sdkRootPath = path
        saveSettings()
    }

    func updateAVDName(_ name: String) {
        settings.avdName = name
        saveSettings()
    }

    func updateWatchFolderPath(_ path: String) {
        settings.watchFolderPath = path
        ensureWatchFolderExists()
        saveSettings()
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
            restartFolderMonitor()
            Task {
                await refreshFolderCatalog()
            }
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
        Task {
            await refreshFolderCatalog()
            scheduleFolderScan(reason: "Manual rescan")
        }
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
                environment: toolchain.environment
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
                    : "Ready to start a headless Android runtime"
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
        await refreshFolderCatalog()

        if settings.autoStartRuntime {
            startRuntime()
        }
    }

    /// Launches a fresh headless emulator, waits for Android services to come online, then starts
    /// folder scanning and periodic health checks.
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

            ensureWatchFolderExists()

            let existingDevices = try await connectedDeviceSerials(using: toolchain)
            let emulator = try Shell.spawn(
                executable: toolchain.emulator.path,
                arguments: [
                    "-avd", settings.avdName,
                    "-no-window",
                    "-no-audio",
                    "-no-boot-anim",
                    "-no-snapshot-save",
                    "-gpu", "swiftshader_indirect",
                    "-netdelay", "none",
                    "-netspeed", "full",
                ],
                environment: toolchain.environment
            )

            emulatorProcess = emulator
            appendLog("Emulator process launched for AVD \(settings.avdName)")

            let serial = try await waitForFreshDevice(using: toolchain, excluding: existingDevices)
            connectedDevice = serial
            appendLog("Device connected as \(serial)")

            try await waitForBoot(using: toolchain, serial: serial)
            appendLog("Android runtime boot completed")

            restartFolderMonitor()
            knownAPKs.removeAll()
            runtimeState = .running
            statusMessage = "Watching \(watchFolderURL.lastPathComponent) for APKs"
            try await refreshInstalledPackages(using: toolchain, serial: serial)
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

    /// The app only manages emulator devices, so physical phones are filtered out here.
    private func connectedDeviceSerials(using toolchain: AndroidToolchain) async throws -> Set<String> {
        let output = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["devices"],
            environment: toolchain.environment
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
            environment: toolchain.environment
        )

        if bootCompleted.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return true
        }

        let bootAnimation = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["-s", serial, "shell", "getprop", "init.svc.bootanim"],
            environment: toolchain.environment
        )

        guard bootAnimation.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "stopped" else {
            return false
        }

        let packageManager = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["-s", serial, "shell", "pm", "list", "packages"],
            environment: toolchain.environment
        )

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

        let output = try await Shell.run(
            executable: toolchain.adb.path,
            arguments: ["-s", serial, "install", "-r", apkURL.path],
            environment: toolchain.environment
        )

        guard output.status == 0, output.stdout.localizedCaseInsensitiveContains("success") else {
            let message = [output.stderr, output.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            throw RuntimeError.installFailed(message.isEmpty ? "Unknown adb install error" : message)
        }

        appendLog("Installed \(apkURL.lastPathComponent)")

        guard launchAfterInstall else {
            return
        }

        guard let packageName = try await packageName(for: apkURL, using: toolchain) else {
            appendLog("Installed \(apkURL.lastPathComponent) but could not infer its package name for auto-launch")
            return
        }

        try await launchPackageAfterInstall(named: packageName, using: toolchain, serial: serial)
    }

    /// Package-name inference prefers `apkanalyzer`, but `aapt` remains a reliable fallback when
    /// only Android build-tools are installed.
    private func packageName(for apkURL: URL, using toolchain: AndroidToolchain) async throws -> String? {
        if let apkanalyzer = toolchain.apkanalyzer {
            let output = try? await Shell.run(
                executable: apkanalyzer.path,
                arguments: ["manifest", "application-id", apkURL.path],
                environment: toolchain.environment
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
                environment: toolchain.environment
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

            try await launchPackage(named: packageName, using: toolchain, serial: serial)
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

    /// Launches the best known launcher activity for a package, falling back to `monkey` only when
    /// Android cannot resolve a concrete launcher component yet.
    private func launchPackage(named packageName: String, using toolchain: AndroidToolchain, serial: String) async throws {
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
                environment: toolchain.environment
            )

            guard launch.status == 0 else {
                let message = [launch.stderr, launch.stdout]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                throw RuntimeError.launchFailed(message.isEmpty ? componentName : message)
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
            environment: toolchain.environment
        )

        guard fallback.status == 0 else {
            let message = [fallback.stderr, fallback.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            throw RuntimeError.launchFailed(message.isEmpty ? packageName : message)
        }

        appendLog("Launched \(packageName)")
    }

    /// Newly installed packages can report a successful install before their launcher entry is
    /// queryable. Retry launch a few times so automatic post-install opens are reliable.
    private func launchPackageAfterInstall(
        named packageName: String,
        using toolchain: AndroidToolchain,
        serial: String
    ) async throws {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            do {
                try await launchPackage(named: packageName, using: toolchain, serial: serial)
                return
            } catch {
                guard attempt < maxAttempts else {
                    throw error
                }

                appendLog("Retrying launch for \(packageName) after install (\(attempt + 1)/\(maxAttempts))")
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
            environment: toolchain.environment
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
            environment: toolchain.environment
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
            environment: toolchain.environment
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
            environment: toolchain.environment
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

            try await launchPackage(named: request.packageName, using: toolchain, serial: serial)
            statusMessage = "Launched \(request.displayName ?? request.packageName)"
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
            environment: toolchain.environment
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
        let invalid = CharacterSet(charactersIn: "/:\\")
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        let sanitized = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Android App" : sanitized
    }

    private func ensureWatchFolderExists() {
        let folder = watchFolderURL

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            appendLog("Unable to create watch folder: \(error.localizedDescription)")
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

    private func appendLog(_ message: String) {
        logs.insert(LogEntry(timestamp: Date(), message: message), at: 0)

        if logs.count > 150 {
            logs.removeLast(logs.count - 150)
        }
    }
}
