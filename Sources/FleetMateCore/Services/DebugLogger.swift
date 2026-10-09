import Foundation
import os.log

/// Centralized debug logger that writes to both os_log (Console.app) and a log file.
/// View live from terminal:  tail -f ~/.fleetmate/debug.log
/// View in Console.app:     filter by subsystem "com.fleetmate"
public final class DebugLogger {
    public static let shared = DebugLogger()

    private let osLog = Logger(subsystem: "com.fleetmate", category: "app")
    private let logFileURL: URL
    private var fileHandle: FileHandle?
    private var writesSinceCheck = 0
    private static let rotateSize: UInt64 = 2_000_000
    private let queue = DispatchQueue(label: "com.fleetmate.debuglogger")
    private let startTime = Date()
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let dir = URL(fileURLWithPath: NSString(string: AppEdition.current.logDirectory).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        logFileURL = dir.appendingPathComponent("debug.log")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64, size > Self.rotateSize {
            rotate()
        }
        openLogFile()

        let separator = "\n" + String(repeating: "=", count: 80) + "\n"
        let header = "\(separator)\(AppEdition.current.displayName) launched at \(ISO8601DateFormatter().string(from: Date()))\n\(separator)\n"
        write(header)
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Public API

    public func log(_ message: String, category: String = "general", level: LogLevel = .info) {
        let now = Date()
        let ts = timestampFormatter.string(from: now)
        let elapsed = String(format: "%.3f", now.timeIntervalSince(startTime))
        let line = "[\(ts)] [\(elapsed)s] [\(category)] \(level.prefix) \(message)"

        // stderr (visible when app is launched from terminal)
        queue.async {
            self.write(line + "\n")
            fputs(line + "\n", stderr)
        }

        // os_log (visible in Console.app)
        switch level {
        case .debug: osLog.debug("\(line, privacy: .public)")
        case .info:  osLog.info("\(line, privacy: .public)")
        case .warn:  osLog.warning("\(line, privacy: .public)")
        case .error: osLog.error("\(line, privacy: .public)")
        }
    }

    public func debug(_ message: String, category: String = "general") {
        log(message, category: category, level: .debug)
    }

    public func info(_ message: String, category: String = "general") {
        log(message, category: category, level: .info)
    }

    public func warn(_ message: String, category: String = "general") {
        log(message, category: category, level: .warn)
    }

    public func error(_ message: String, category: String = "general") {
        log(message, category: category, level: .error)
    }

    /// Log file path (for display in UI or terminal)
    public var logFilePath: String { logFileURL.path }

    // MARK: - Internal

    private func write(_ text: String) {
        writesSinceCheck += 1
        if writesSinceCheck >= 200 {
            writesSinceCheck = 0
            checkLogFile()
        }
        if let data = text.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    private func openLogFile() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logFileURL.path)
        fileHandle?.seekToEndOfFile()
    }

    private func rotate() {
        let backup = logFileURL.deletingLastPathComponent().appendingPathComponent("debug.log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: logFileURL, to: backup)
    }

    /// The app and the CLI share one log, and the app runs for days. Rotate
    /// at the size cap while running, and reopen when another process has
    /// rotated the file away, so lines never keep landing in debug.log.1.
    private func checkLogFile() {
        guard let handle = fileHandle else { return }
        var open = stat()
        var onDisk = stat()
        let moved = fstat(handle.fileDescriptor, &open) != 0
            || stat(logFileURL.path, &onDisk) != 0
            || open.st_ino != onDisk.st_ino
        if !moved && UInt64(open.st_size) <= Self.rotateSize { return }
        handle.closeFile()
        if !moved { rotate() }
        openLogFile()
    }

    public enum LogLevel {
        case debug, info, warn, error

        var prefix: String {
            switch self {
            case .debug: return "DEBUG"
            case .info:  return "INFO "
            case .warn:  return "WARN "
            case .error: return "ERROR"
            }
        }
    }
}

/// Convenience shorthand
public let dbg = DebugLogger.shared
