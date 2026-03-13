import Foundation

/// Captures the parts of a child process result that the runtime cares about.
struct ShellOutput: Sendable {
    let stdout: String
    let stderr: String
    let status: Int32
}

/// Small async process wrapper used for `adb`, `emulator`, `apkanalyzer`, and `aapt`.
enum Shell {
    static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> ShellOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            var mergedEnvironment = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                mergedEnvironment[key] = value
            }
            process.environment = mergedEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

                continuation.resume(returning: ShellOutput(
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self),
                    status: process.terminationStatus
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func spawn(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> Process {
        let process = Process()
        let nullDevice = FileHandle.nullDevice

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = nullDevice
        process.standardOutput = nullDevice
        process.standardError = nullDevice

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment

        try process.run()
        return process
    }
}
