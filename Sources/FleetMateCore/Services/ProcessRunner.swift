import Foundation

/// The result of running a child process to completion.
public struct ProcessOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    /// True when the process ran and exited 0. A process that never launched
    /// reports `exitCode == -1` with the reason in `stderr`.
    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// One place to spawn a child process.
///
/// Every call site used to build its own `Process` + two `Pipe`s and read them
/// inline. That pattern leaks two file descriptors per spawn: `Process` closes
/// only the *write* ends when the child is exec'd, and nothing ever closes the
/// read ends — `readDataToEndOfFile()` reads to EOF but leaves the descriptor
/// open. A GUI app launched from Finder inherits `RLIMIT_NOFILE` of 256, so a
/// poller that spawns `gh` or `az` on a timer exhausts the table after a few
/// hundred calls. From then on `Process.run()` throws `EBADF` for the rest of
/// the app's life, which surfaced as a permanent, un-recoverable
/// "No GitHub authentication token available" hours into an otherwise healthy
/// session.
///
/// This helper closes both read ends on every path, and drains stdout and
/// stderr concurrently — reading them in sequence deadlocks whenever a child
/// writes more than a pipe buffer (~64 KB) to the stream that is read second.
public enum ProcessRunner {

    /// Directories a GUI app's inherited `PATH` is missing.
    static let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Absolute path for a CLI tool, or the bare name if it isn't installed in
    /// a known location — a GUI app's `PATH` has no Homebrew, so bare names
    /// resolve only through the `/usr/bin/env` fallback.
    public static func resolve(_ name: String) -> String {
        if name.hasPrefix("/") { return name }
        for directory in toolDirectories {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return name
    }

    /// Runs `executable` to completion and returns its output. Blocking; call
    /// it off the main thread, or use the `async` overload below.
    ///
    /// - Parameter executable: an absolute path, or a bare tool name to resolve.
    /// - Parameter environment: replaces the inherited environment when given.
    ///   `PATH` is widened either way.
    /// - Parameter inheritStandardInput: pass true only for a genuinely
    ///   interactive tool run from the CLI (`az login` prompting in a terminal).
    ///   A GUI app must leave this false so a child can never block on input.
    public static func runSync(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        inheritStandardInput: Bool = false
    ) -> ProcessOutput {
        let resolved = resolve(executable)
        let process = Process()
        if resolved.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [resolved] + arguments
        }

        var env = environment ?? ProcessInfo.processInfo.environment
        env["PATH"] = (toolDirectories + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Never let a child block waiting on input it will never get.
        process.standardInput = inheritStandardInput ? FileHandle.standardInput : FileHandle.nullDevice

        // The whole point of this type: the read ends close on every exit path,
        // including the launch failure below.
        defer {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }

        do {
            try process.run()
        } catch {
            // No child was spawned, so `Process` never closed the parent's copy
            // of the write ends — on this path only, we own them. On the
            // success path they are already closed and must not be touched:
            // those numbers may have been handed to unrelated I/O by then.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            return ProcessOutput(
                stdout: "",
                stderr: "could not launch \(executable): \(error.localizedDescription)",
                exitCode: -1
            )
        }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            outData = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            errData = err.fileHandleForReading.readDataToEndOfFile()
        }
        group.wait()
        process.waitUntilExit()

        return ProcessOutput(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// `runSync` moved off the calling thread, so an actor or the main queue is
    /// never blocked waiting on a child process.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        inheritStandardInput: Bool = false
    ) async -> ProcessOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(
                    executable, arguments,
                    environment: environment,
                    inheritStandardInput: inheritStandardInput
                ))
            }
        }
    }

    /// Trimmed stdout when the process exited 0, else nil — the common shape
    /// for "ask a CLI for one value".
    public static func trimmedOutput(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async -> String? {
        let result = await run(executable, arguments, environment: environment)
        guard result.succeeded else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
