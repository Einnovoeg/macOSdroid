import Foundation

/// High-level lifecycle state for the hidden Android runtime.
enum RuntimeState: String {
    case stopped
    case starting
    case running
    case stopping
    case failed

    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .stopping:
            "Stopping"
        case .failed:
            "Needs Attention"
        }
    }
}

/// Lightweight activity item shown in the dashboard log pane.
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

/// File-based fingerprint used to decide whether an APK should be reinstalled.
struct APKFingerprint: Equatable {
    let fileSize: Int64
    let modifiedAt: Date
}

/// Metadata shown in the library view and reused for launcher generation.
struct APKMetadata: Equatable {
    let displayName: String
    let packageName: String?
}

/// Keeps metadata aligned with the file fingerprint it was derived from.
struct APKMetadataCacheEntry: Equatable {
    let fingerprint: APKFingerprint
    let metadata: APKMetadata
}

/// Represents a queued launcher request coming from Finder or the custom URL scheme.
struct LaunchRequest: Equatable {
    let packageName: String
    let displayName: String?
}

/// The dashboard-facing model for one APK discovered inside the watched folder.
struct FolderApp: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    let displayName: String
    let packageName: String?
    let modifiedAt: Date
    let fileSize: Int64
    let installState: FolderAppInstallState

    var fileName: String {
        fileURL.lastPathComponent
    }
}

/// Install state is intentionally coarse so it can be derived from `pm list packages`.
enum FolderAppInstallState: Equatable {
    case unknown
    case notInstalled
    case installed

    var title: String {
        switch self {
        case .unknown:
            "Unknown"
        case .notInstalled:
            "Not Installed"
        case .installed:
            "Installed"
        }
    }
}

/// User-facing runtime errors shown in the UI and activity log.
enum RuntimeError: LocalizedError {
    case sdkMissing
    case avdMissing
    case watchFolderMissing
    case emulatorLaunchFailed(String)
    case emulatorBootTimedOut
    case noEmulatorDevice
    case installFailed(String)
    case launchFailed(String)
    case uninstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .sdkMissing:
            "Android SDK not found. Point macOSdroid at a valid SDK with the emulator and platform-tools installed."
        case .avdMissing:
            "Choose an Android Virtual Device before starting the runtime."
        case .watchFolderMissing:
            "Pick a folder for incoming APKs before starting the runtime."
        case .emulatorLaunchFailed(let message):
            "The Android Emulator failed to launch: \(message)"
        case .emulatorBootTimedOut:
            "The Android runtime did not finish booting before the timeout."
        case .noEmulatorDevice:
            "No emulator device became available."
        case .installFailed(let message):
            "APK install failed: \(message)"
        case .launchFailed(let message):
            "App launch failed: \(message)"
        case .uninstallFailed(let message):
            "App uninstall failed: \(message)"
        }
    }
}
