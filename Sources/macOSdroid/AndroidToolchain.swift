import Foundation

/// Resolves the host-side Android tools that macOSdroid needs in order to boot an emulator
/// and inspect incoming APK files.
struct AndroidToolchain: Sendable {
    let sdkRoot: URL
    let emulator: URL
    let adb: URL
    let apkanalyzer: URL?
    let aapt: URL?
    let javaHome: URL?

    /// The emulator and APK inspection tools are sensitive to both the SDK root and the selected
    /// JDK, so every spawned subprocess inherits this curated environment instead of relying on
    /// the user's shell profile.
    var environment: [String: String] {
        var values = [
            "ANDROID_HOME": sdkRoot.path,
            "ANDROID_SDK_ROOT": sdkRoot.path,
        ]

        if let javaHome {
            values["JAVA_HOME"] = javaHome.path
            values["PATH"] = "\(javaHome.appendingPathComponent("bin").path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        }

        return values
    }

    /// Picks the first SDK root that contains a runnable emulator plus `adb`.
    static func resolve(preferredPath: String) -> AndroidToolchain? {
        for candidate in candidateSDKRoots(preferredPath: preferredPath) {
            let emulator = candidate.appendingPathComponent("emulator/emulator")
            let adb = candidate.appendingPathComponent("platform-tools/adb")

            guard FileManager.default.isExecutableFile(atPath: emulator.path) else {
                continue
            }

            guard FileManager.default.isExecutableFile(atPath: adb.path) else {
                continue
            }

            return AndroidToolchain(
                sdkRoot: candidate,
                emulator: emulator,
                adb: adb,
                apkanalyzer: findApkAnalyzer(in: candidate),
                aapt: findBuildTool(named: "aapt", in: candidate),
                javaHome: preferredJavaHome()
            )
        }

        return nil
    }

    /// Search order prefers explicit configuration first, then environment variables, then
    /// conventional installation locations used by Android Studio and Homebrew.
    private static func candidateSDKRoots(preferredPath: String) -> [URL] {
        var roots: [URL] = []
        let environment = ProcessInfo.processInfo.environment

        if !preferredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            roots.append(URL(fileURLWithPath: NSString(string: preferredPath).expandingTildeInPath))
        }

        if let sdkRoot = environment["ANDROID_SDK_ROOT"], !sdkRoot.isEmpty {
            roots.append(URL(fileURLWithPath: NSString(string: sdkRoot).expandingTildeInPath))
        }

        if let androidHome = environment["ANDROID_HOME"], !androidHome.isEmpty {
            roots.append(URL(fileURLWithPath: NSString(string: androidHome).expandingTildeInPath))
        }

        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk"))
        roots.append(URL(fileURLWithPath: "/opt/homebrew/share/android-commandlinetools"))
        roots.append(URL(fileURLWithPath: "/opt/android-sdk"))

        var deduplicated: [URL] = []
        var seen = Set<String>()

        for root in roots {
            let standardized = root.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                deduplicated.append(standardized)
            }
        }

        return deduplicated
    }

    /// `apkanalyzer` lives under the command-line tools package and is optional because the app
    /// can fall back to `aapt` when only build-tools are installed.
    private static func findApkAnalyzer(in sdkRoot: URL) -> URL? {
        let candidates = [
            sdkRoot.appendingPathComponent("cmdline-tools/latest/bin/apkanalyzer"),
            sdkRoot.appendingPathComponent("cmdline-tools/bin/apkanalyzer"),
            sdkRoot.appendingPathComponent("tools/bin/apkanalyzer"),
        ]

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    /// Build-tools are versioned folders, so prefer the newest installed `aapt`.
    private static func findBuildTool(named name: String, in sdkRoot: URL) -> URL? {
        let buildToolsRoot = sdkRoot.appendingPathComponent("build-tools", isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: buildToolsRoot,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        let ordered = contents.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
        }

        for version in ordered {
            let tool = version.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: tool.path) {
                return tool
            }
        }

        return nil
    }

    /// Prefer JDK 17 because it satisfies the Android command-line tools on current macOS hosts
    /// and remains broadly available from Homebrew and Temurin distributions.
    private static func preferredJavaHome() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []

        if let javaHome = environment["JAVA_HOME"], !javaHome.isEmpty {
            candidates.append(URL(fileURLWithPath: NSString(string: javaHome).expandingTildeInPath))
        }

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"))
        candidates.append(URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines/openjdk-17.jdk/Contents/Home"))
        candidates.append(URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home"))

        for candidate in candidates {
            let java = candidate.appendingPathComponent("bin/java")
            if FileManager.default.isExecutableFile(atPath: java.path) {
                return candidate
            }
        }

        return nil
    }
}
