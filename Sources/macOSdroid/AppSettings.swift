import Foundation

/// Persists the app's host-side configuration and applies environment overrides for automated
/// setups or packaged deployments.
struct AppSettings: Codable, Sendable {
    static let storageKey = "macOSdroid.settings"
    static let legacyDomains = ["com.codex.macosdroid"]

    var sdkRootPath: String
    var avdName: String
    var watchFolderPath: String
    var autoLaunchAfterInstall: Bool
    var autoStartRuntime: Bool
    var menuBarOnly: Bool
    var launchAtLogin: Bool

    enum CodingKeys: String, CodingKey {
        case sdkRootPath
        case avdName
        case watchFolderPath
        case autoLaunchAfterInstall
        case autoStartRuntime
        case menuBarOnly
        case launchAtLogin
    }

    init(
        sdkRootPath: String,
        avdName: String,
        watchFolderPath: String,
        autoLaunchAfterInstall: Bool,
        autoStartRuntime: Bool,
        menuBarOnly: Bool,
        launchAtLogin: Bool
    ) {
        self.sdkRootPath = sdkRootPath
        self.avdName = avdName
        self.watchFolderPath = watchFolderPath
        self.autoLaunchAfterInstall = autoLaunchAfterInstall
        self.autoStartRuntime = autoStartRuntime
        self.menuBarOnly = menuBarOnly
        self.launchAtLogin = launchAtLogin
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
                sdkRootPath: "",
                avdName: "",
                watchFolderPath: defaultWatchFolder.path,
                autoLaunchAfterInstall: true,
                autoStartRuntime: false,
                menuBarOnly: true,
                launchAtLogin: false
            )
        }

        return applyingEnvironmentOverrides(to: baseSettings)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }

        UserDefaults.standard.set(data, forKey: AppSettings.storageKey)
    }

    static var defaultWatchFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("macOSdroid Inbox", isDirectory: true)
    }

    static var defaultLauncherFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("macOSdroid Launchers", isDirectory: true)
    }

    private static func applyingEnvironmentOverrides(to settings: AppSettings) -> AppSettings {
        let environment = ProcessInfo.processInfo.environment
        var resolved = settings

        if let sdkRootPath = environment["MACOSDROID_SDK_ROOT"], !sdkRootPath.isEmpty {
            resolved.sdkRootPath = sdkRootPath
        }

        if let avdName = environment["MACOSDROID_AVD_NAME"], !avdName.isEmpty {
            resolved.avdName = avdName
        }

        if let watchFolderPath = environment["MACOSDROID_WATCH_FOLDER"], !watchFolderPath.isEmpty {
            resolved.watchFolderPath = NSString(string: watchFolderPath).expandingTildeInPath
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
}
