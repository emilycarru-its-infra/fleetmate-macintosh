import Foundation

/// The signed-in user's GitHub notification inbox, read and written through
/// the REST notifications API. The `repo` scope the gh CLI token carries
/// already covers it, so no extra login is needed.
public actor GitHubNotificationService {
    private let client: GitHubGraphQLClient

    public init(config: GitHubProviderConfig) {
        self.client = GitHubGraphQLClient(config: config)
    }

    /// Notification threads, newest first.
    ///
    /// - Parameters:
    ///   - includeRead: `true` returns read threads too (GitHub's "all"); the
    ///     default is unread only, which is what an inbox is for.
    ///   - limit: Page size, capped by GitHub at 50.
    public func getNotifications(includeRead: Bool = false, limit: Int = 50) async throws -> [GitHubNotification] {
        let path = "/notifications?all=\(includeRead)&participating=false&per_page=\(min(limit, 50))"
        let data = try await client.executeREST(path: path)
        let threads = try JSONDecoder().decode([RestThread].self, from: data)
        let mapped = threads.map(Self.map)
        dbg.info("GitHub getNotifications(all=\(includeRead)) → \(mapped.count)", category: "github")
        return mapped
    }

    /// Marks one thread read. It stays in the "all" list, drops out of unread.
    public func markRead(threadId: String) async throws {
        _ = try await client.executeREST(method: "PATCH", path: "/notifications/threads/\(threadId)")
    }

    /// Marks a thread done: GitHub removes it from the inbox entirely.
    public func markDone(threadId: String) async throws {
        _ = try await client.executeREST(method: "DELETE", path: "/notifications/threads/\(threadId)")
    }

    /// Stops future notifications for the thread and marks it read.
    public func unsubscribe(threadId: String) async throws {
        _ = try await client.executeREST(method: "DELETE", path: "/notifications/threads/\(threadId)/subscription")
    }

    /// Marks every notification updated up to now as read. GitHub applies it
    /// asynchronously, so a refresh immediately after can still show a few.
    public func markAllRead() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        _ = try await client.executeREST(method: "PUT", path: "/notifications", body: [
            "last_read_at": formatter.string(from: Date()),
            "read": true
        ])
    }

    // MARK: - Mapping

    private static func map(_ thread: RestThread) -> GitHubNotification {
        GitHubNotification(
            id: thread.id,
            reason: GitHubNotificationReason(raw: thread.reason),
            unread: thread.unread ?? false,
            updatedAt: PullRequestDateParser.parse(thread.updatedAt),
            lastReadAt: PullRequestDateParser.parse(thread.lastReadAt),
            subjectTitle: thread.subject?.title ?? "(untitled)",
            subjectType: GitHubNotificationSubjectType(raw: thread.subject?.type),
            subjectApiUrl: thread.subject?.url,
            repository: thread.repository?.fullName ?? "",
            repositoryWebUrl: thread.repository?.htmlUrl ?? "https://github.com"
        )
    }

    private struct RestThread: Decodable {
        let id: String
        let unread: Bool?
        let reason: String?
        let updatedAt: String?
        let lastReadAt: String?
        let subject: Subject?
        let repository: Repository?

        struct Subject: Decodable {
            let title: String?
            let url: String?
            let type: String?
        }
        struct Repository: Decodable {
            let fullName: String?
            let htmlUrl: String?
            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
                case htmlUrl = "html_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case id, unread, reason, subject, repository
            case updatedAt = "updated_at"
            case lastReadAt = "last_read_at"
        }
    }
}
