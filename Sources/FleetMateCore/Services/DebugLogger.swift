import Foundation
import os.log

/// Centralized debug logger that writes to both os_log (Console.app) and a log file.
/// View live from terminal:  tail -f ~/.fleetmate/debug.log
/// View in Console.app:     filter by subsystem "com.fleetmate"
public final class DebugLogger {
    public static let shared = DebugLogger()

    private let osLog = Logger(subsystem: "com.fleetmate", category: "app")
    private let logFileURL: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.fleetmate.debuglogger")
    private let startTime = Date()
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fleetmate")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        logFileURL = dir.appendingPathComponent("debug.log")

        // Rotate if > 2 MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64, size > 2_000_000 {
            let backup = dir.appendingPathComponent("debug.log.1")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: logFileURL, to: backup)
        }

        // Create file if needed
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logFileURL.path)
        fileHandle?.seekToEndOfFile()

        let separator = "\n" + String(repeating: "=", count: 80) + "\n"
        let header = "\(separator)FleetMate launched at \(ISO8601DateFormatter().string(from: Date()))\n\(separator)\n"
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
        if let data = text.data(using: .utf8) {
            fileHandle?.write(data)
        }
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
