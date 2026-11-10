import Foundation
import UniformTypeIdentifiers

/// A single bounded download. No shared cookie jar, credential storage or response cache.
public final class AttachmentDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let maximumBytes: Int64 = 50 * 1_024 * 1_024
    private let access: AttachmentAccess
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var result: URL?
    private var failure: Error?
    private var redirectCount = 0
    private let destination: URL

    public init(access: AttachmentAccess, name: String) throws {
        self.access = access
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FleetMateAttachment-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safeName = (name as NSString).lastPathComponent
        destination = directory.appendingPathComponent(safeName.isEmpty || safeName == "." || safeName == ".." ? "Attachment" : safeName)
    }

    deinit { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

    public func download(_ url: URL, token: String?) async throws -> URL {
        guard access.allows(url) else { throw DownloadError.disallowed }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 90
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url)
                if access.mayAuthorize(url), let token, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirectCount += 1
        guard redirectCount <= 5, let url = request.url, access.allows(url) else { completionHandler(nil); return }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        stripped.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(stripped)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumBytes || totalBytesExpectedToWrite > Self.maximumBytes {
            failure = DownloadError.tooLarge
            downloadTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { throw DownloadError.unavailable }
            guard response.mimeType?.lowercased() != "text/html" else { throw DownloadError.signIn }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumBytes else { throw DownloadError.tooLarge }
            var output = destination
            if output.pathExtension.isEmpty, let mime = response.mimeType,
               let suffix = UTType(mimeType: mime)?.preferredFilenameExtension {
                output.appendPathExtension(suffix)
            }
            try FileManager.default.moveItem(at: location, to: output)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            result = output
        } catch { failure = error }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure = failure ?? error { continuation?.resume(throwing: failure) }
        else if let result { continuation?.resume(returning: result) }
        else { continuation?.resume(throwing: DownloadError.unavailable) }
    }

    public enum DownloadError: LocalizedError {
        case disallowed, tooLarge, unavailable, signIn
        public var errorDescription: String? {
            switch self {
            case .disallowed: return "This attachment host is not supported. Open the original link in your browser."
            case .tooLarge: return "This attachment exceeds the 50 MB preview limit."
            case .unavailable: return "The attachment could not be downloaded. You can open the original link in your browser."
            case .signIn: return "The attachment requires browser sign-in. Open the original link in your browser."
            }
        }
    }
}
