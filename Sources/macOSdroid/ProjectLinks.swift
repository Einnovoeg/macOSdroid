import Foundation

/// Centralizes upstream references that help users review the licenses and terms for external
/// dependencies required to run macOSdroid.
enum ProjectLinks {
    static let androidSDKTerms = URL(string: "https://developer.android.com/studio/terms")!
    static let openJDKLicense = URL(string: "https://openjdk.org/legal/gplv2+ce.html")!
    static let scrcpyProject = URL(string: "https://github.com/Genymobile/scrcpy")!
    static let swiftLicense = URL(string: "https://www.swift.org/license/")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/einnovoeg")!
}
