import Darwin
import Foundation

/// Captures the parts of a child process result that the runtime cares about.
struct ShellOutput: Sendable {
    let stdout: String
    let stderr: String
    let status: Int32
}

/// Structured subprocess failure so higher-level runtime code can distinguish hung tools from
/// normal non-zero exits.
enum ShellError: LocalizedError {
    case timedOut(command: String, after: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let command, let after):
            return "Command timed out after \(Int(after))s: \(command)"
        }
    }
}

private final class ShellContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<ShellOutput, Error>

    init(continuation: CheckedContinuation<ShellOutput, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<ShellOutput, Error>) {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else {
            return
        }

        didResume = true
        continuation.resume(with: result)
    }
}

/// Small async process wrapper used for `adb`, `emulator`, `apkanalyzer`, and `aapt`.
enum Shell {
    static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> ShellOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let box = ShellContinuationBox(continuation: continuation)

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

                box.resume(.success(ShellOutput(
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self),
                    status: process.terminationStatus
                )))
            }

            do {
                try process.run()
            } catch {
                box.resume(.failure(error))
                return
            }

            guard let timeout else {
                return
            }

            Task.detached {
                let delay = UInt64(timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)

                guard process.isRunning else {
                    return
                }

                process.terminate()
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }

                let command = ([executable] + arguments).joined(separator: " ")
                box.resume(.failure(ShellError.timedOut(command: command, after: timeout)))
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
