import Foundation

/// Persists the app's host-side configuration and applies environment overrides for automated
/// setups or packaged deployments.
struct AppSettings: Codable, Equatable, Sendable {
    static let storageKey = "macOSdroid.settings"
    static let legacyDomains = ["com.codex.macosdroid"]
    static let defaultBundleIdentifier = "io.macosdroid.app"

    var sdkRootPath: String
    var avdName: String
    var watchFolderPath: String
    var autoLaunchAfterInstall: Bool
    var autoStartRuntime: Bool
    var menuBarOnly: Bool
    var launchAtLogin: Bool
    var showAndroidWindow: Bool
    var preferSeparateAppWindows: Bool

    enum CodingKeys: String, CodingKey {
        case sdkRootPath
        case avdName
        case watchFolderPath
        case autoLaunchAfterInstall
        case autoStartRuntime
        case menuBarOnly
        case launchAtLogin
        case showAndroidWindow
        case preferSeparateAppWindows
    }

    init(
        sdkRootPath: String,
        avdName: String,
        watchFolderPath: String,
        autoLaunchAfterInstall: Bool,
        autoStartRuntime: Bool,
        menuBarOnly: Bool,
        launchAtLogin: Bool,
        showAndroidWindow: Bool,
        preferSeparateAppWindows: Bool
    ) {
        self.sdkRootPath = sdkRootPath
        self.avdName = avdName
        self.watchFolderPath = watchFolderPath
        self.autoLaunchAfterInstall = autoLaunchAfterInstall
        self.autoStartRuntime = autoStartRuntime
        self.menuBarOnly = menuBarOnly
        self.launchAtLogin = launchAtLogin
        self.showAndroidWindow = showAndroidWindow
        self.preferSeparateAppWindows = preferSeparateAppWindows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sdkRootPath = try container.decodeIfPresent(String.self, forKey: .sdkRootPath) ?? ""
        avdName = try container.decodeIfPresent(String.self, forKey: .avdName) ?? ""
        watchFolderPath = try container.decodeIfPresent(String.self, forKey: .watchFolderPath) ?? AppSettings.defaultWatchFolder.path
        autoLaunchAfterInstall = try container.decodeIfPresent(Bool.self, forKey: .autoLaunchAfterInstall) ?? true
        autoStartRuntime = try container.decodeIfPresent(Bool.self, forKey: .autoStartRuntime) ?? false
        menuBarOnly = try container.decodeIfPresent(Bool.self, forKey: .menuBarOnly) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showAndroidWindow = try container.decodeIfPresent(Bool.self, forKey: .showAndroidWindow) ?? false
        preferSeparateAppWindows = try container.decodeIfPresent(Bool.self, forKey: .preferSeparateAppWindows) ?? true
    }

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        let baseSettings: AppSettings

        if
            let data = defaults.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            baseSettings = settings
        } else if let migrated = loadLegacySettings() {
            migrated.save()
            baseSettings = migrated
        } else {
            baseSettings = AppSettings(
                sdkRootPath: defaultManagedSDKRoot.path,
                avdName: "",
                watchFolderPath: defaultWatchFolder.path,
                autoLaunchAfterInstall: true,
                autoStartRuntime: false,
                menuBarOnly: true,
                launchAtLogin: false,
                showAndroidWindow: false,
                preferSeparateAppWindows: true
            )
        }

        let normalizedSettings = normalizedManagedPaths(from: baseSettings)
        if normalizedSettings != baseSettings {
            normalizedSettings.save()
        }

        return applyingEnvironmentOverrides(to: normalizedSettings)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }

        UserDefaults.standard.set(data, forKey: AppSettings.storageKey)
        UserDefaults.standard.synchronize()
    }

    static var defaultWatchFolder: URL {
        applicationSupportDirectory
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    static var defaultLauncherFolder: URL {
        applicationSupportDirectory
            .appendingPathComponent("Launchers", isDirectory: true)
    }

    static var logsDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("Logs", isDirectory: true)
    }

    static var activityLogFile: URL {
        logsDirectory
            .appendingPathComponent("activity.log", isDirectory: false)
    }

    static var runtimeSetupLogFile: URL {
        logsDirectory
            .appendingPathComponent("runtime-setup.log", isDirectory: false)
    }

    static var defaultManagedSDKRoot: URL {
        applicationSupportDirectory
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("android-sdk", isDirectory: true)
    }

    static var managedAndroidUserHome: URL {
        applicationSupportDirectory
            .appendingPathComponent("AndroidUserHome", isDirectory: true)
    }

    static var managedAVDDirectory: URL {
        managedAndroidUserHome
            .appendingPathComponent("avd", isDirectory: true)
    }

    static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("macOSdroid", isDirectory: true)
    }

    static var legacyDefaultSDKRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk", isDirectory: true)
    }

    static var legacyDefaultWatchFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("macOSdroid Inbox", isDirectory: true)
    }

    static var legacyDefaultLauncherFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("macOSdroid Launchers", isDirectory: true)
    }

    private static func applyingEnvironmentOverrides(to settings: AppSettings) -> AppSettings {
        let environment = ProcessInfo.processInfo.environment
        var resolved = settings

        if let sdkRootPath = environment["MACOSDROID_SDK_ROOT"], !sdkRootPath.isEmpty {
            resolved.sdkRootPath = normalizedPath(sdkRootPath)
        }

        if let avdName = environment["MACOSDROID_AVD_NAME"], !avdName.isEmpty {
            resolved.avdName = avdName
        }

        if let watchFolderPath = environment["MACOSDROID_WATCH_FOLDER"], !watchFolderPath.isEmpty {
            resolved.watchFolderPath = normalizedPath(watchFolderPath)
        }

        if let autoLaunchAfterInstall = boolEnvironmentValue(named: "MACOSDROID_AUTO_LAUNCH") {
            resolved.autoLaunchAfterInstall = autoLaunchAfterInstall
        }

        if let autoStartRuntime = boolEnvironmentValue(named: "MACOSDROID_AUTO_START") {
            resolved.autoStartRuntime = autoStartRuntime
        }

        if let menuBarOnly = boolEnvironmentValue(named: "MACOSDROID_MENU_BAR_ONLY") {
            resolved.menuBarOnly = menuBarOnly
        }

        if let launchAtLogin = boolEnvironmentValue(named: "MACOSDROID_LAUNCH_AT_LOGIN") {
            resolved.launchAtLogin = launchAtLogin
        }

        if let showAndroidWindow = boolEnvironmentValue(named: "MACOSDROID_SHOW_ANDROID_WINDOW") {
            resolved.showAndroidWindow = showAndroidWindow
        }

        if let preferSeparateAppWindows = boolEnvironmentValue(named: "MACOSDROID_USE_APP_WINDOWS") {
            resolved.preferSeparateAppWindows = preferSeparateAppWindows
        }

        return resolved
    }

    /// Keep the app-managed folders under Application Support so packaged installs stay
    /// self-contained and do not repeatedly touch user-visible or removable-volume paths by
    /// default. Existing custom paths are preserved.
    private static func normalizedManagedPaths(from settings: AppSettings) -> AppSettings {
        var resolved = settings
        let managedSDKIsRunnable = sdkRootHasRequiredTools(defaultManagedSDKRoot)
        let legacySDKIsRunnable = sdkRootHasRequiredTools(legacyDefaultSDKRoot)

        let watchFolderPath = NSString(string: resolved.watchFolderPath).expandingTildeInPath
        if watchFolderPath.isEmpty || watchFolderPath == legacyDefaultWatchFolder.path {
            resolved.watchFolderPath = defaultWatchFolder.path
        }

        let sdkRootPath = NSString(string: resolved.sdkRootPath).expandingTildeInPath
        if sdkRootPath.isEmpty {
            resolved.sdkRootPath = managedSDKIsRunnable
                ? defaultManagedSDKRoot.path
                : (legacySDKIsRunnable ? legacyDefaultSDKRoot.path : defaultManagedSDKRoot.path)
        } else if sdkRootPath == legacyDefaultSDKRoot.path, managedSDKIsRunnable {
            resolved.sdkRootPath = defaultManagedSDKRoot.path
        } else if sdkRootPath == defaultManagedSDKRoot.path, !managedSDKIsRunnable, legacySDKIsRunnable {
            resolved.sdkRootPath = legacyDefaultSDKRoot.path
        }

        return resolved
    }

    /// Older builds stored preferences under the previous bundle identifier. Migrate them forward
    /// so packaged updates keep the same SDK, AVD, and inbox configuration.
    private static func loadLegacySettings() -> AppSettings? {
        for domain in legacyDomains {
            guard
                let legacyDefaults = UserDefaults(suiteName: domain),
                let data = legacyDefaults.data(forKey: storageKey),
                let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
            else {
                continue
            }

            return settings
        }

        return nil
    }

    /// Shared parser for boolean environment flags used by the bootstrap and packaged runtime.
    private static func boolEnvironmentValue(named name: String) -> Bool? {
        guard let rawValue = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty
        else {
            return nil
        }

        switch rawValue {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    /// The app can only safely migrate to the managed SDK after both the emulator and `adb`
    /// binaries are present, otherwise a half-finished bootstrap could strand launches.
    private static func sdkRootHasRequiredTools(_ root: URL) -> Bool {
        let fileManager = FileManager.default
        let adb = root.appendingPathComponent("platform-tools/adb")
        let emulator = root.appendingPathComponent("emulator/emulator")
        return fileManager.isExecutableFile(atPath: adb.path) && fileManager.isExecutableFile(atPath: emulator.path)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }
}
