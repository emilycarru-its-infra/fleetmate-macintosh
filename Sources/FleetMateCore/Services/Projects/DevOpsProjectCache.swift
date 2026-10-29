import Foundation
import os

/// Concurrent refreshes must retain a cache snapshot under the same lock that
/// replaces it. Copying an Array while another task replaces its storage races
/// its reference count, even though each caller only reads the returned value.
final class DevOpsProjectCache: Sendable {
    struct Snapshot: Sendable {
        var projects: [DevOpsProject]?
        var expiresAt: Date = .distantPast
        var retryAfter: Date = .distantPast
        var failureLogged = false
    }

    private let storage = OSAllocatedUnfairLock(initialState: Snapshot())

    func snapshot() -> Snapshot {
        storage.withLock { $0 }
    }

    func store(_ projects: [DevOpsProject], now: Date) {
        storage.withLock {
            $0.projects = projects
            $0.expiresAt = now.addingTimeInterval(10 * 60)
            $0.retryAfter = .distantPast
            $0.failureLogged = false
        }
    }

    func recordFailure(now: Date) -> (projects: [DevOpsProject]?, shouldLog: Bool) {
        storage.withLock {
            let shouldLog = !$0.failureLogged
            $0.retryAfter = now.addingTimeInterval(5 * 60)
            $0.failureLogged = true
            return ($0.projects, shouldLog)
        }
    }

    func resetBackoff() {
        storage.withLock { $0.retryAfter = .distantPast }
    }

    func clear() {
        storage.withLock { $0 = Snapshot() }
    }
}
