import AppKit
import FleetMateCore
import SwiftUI

@MainActor
final class TeamsWorkspaceModel: ObservableObject {
    enum Scope: Hashable {
        case all, following, saved
        case collection(String), team(String), channel(String)
    }

    @Published var scope: Scope? = .all
    @Published var query = ""
    @Published var channelQuery = ""
    @Published var author = ""
    @Published var period = TeamsPeriod.anyTime.rawValue
    @Published var expandedTeams: Set<String> = []
    @Published private(set) var channels: [TeamsChannel] = []
    @Published private(set) var hits: [TeamsSearchHit] = []
    @Published private(set) var total = 0
    @Published private(set) var asOf: String?
    @Published private(set) var bookmarks: [TeamsBookmark] = []
    @Published private(set) var followedChannelIDs: Set<String> = []
    @Published private(set) var selectedHit: TeamsSearchHit?
    @Published private(set) var thread: TeamsThread?
    @Published private(set) var channelError: String?
    @Published private(set) var feedError: String?
    @Published private(set) var threadError: String?
    @Published private(set) var bookmarkError: String?
    @Published private(set) var isLoadingChannels = false
    @Published private(set) var isLoadingFeed = false
    @Published private(set) var isLoadingThread = false
    @Published private(set) var hasLoadedFeed = false
    @Published private(set) var nextOffset: Int?
    @Published private(set) var notice: String?
    @Published private(set) var canSave = false

    let config: FleetMateConfig
    let service: TeamsSearchService
    private var bookmarkStore: TeamsBookmarkStore?
    private var indexVersion: String?
    private var feedTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var generation = UUID()
    private var defaultsRestored = false
    private var browseMode = false

    init(config: FleetMateConfig) {
        self.config = config
        service = TeamsSearchService(config: config)
        author = UserDefaults.standard.string(forKey: "teams.author") ?? ""
        period = UserDefaults.standard.string(forKey: "teams.period") ?? TeamsPeriod.anyTime.rawValue
    }

    var linkHosts: [String] { TeamsLinkPolicy.hosts(extra: config.teamsLinkHosts) }
    var isFollowing: Bool { scope == .following }
    var followedChannels: [TeamsChannel] { channels.filter { followedChannelIDs.contains($0.channelId) } }
    var currentChannel: TeamsChannel? {
        guard case .channel(let id) = scope else { return nil }
        return channels.first { $0.channelId == id }
    }
    var isSaved: Bool {
        if case .saved = scope { return true }
        if case .collection = scope { return true }
        return false
    }
    var collections: [String] { Array(Set(bookmarks.map(\.collection).filter { !$0.isEmpty })).sorted() }
    var filteredChannels: [TeamsChannel] {
        let words = channelQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        return channels.filter { channel in
            let text = channel.teamName + " " + channel.channelName
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }
    var teamIDs: [String] {
        var ids: [String] = []
        for channel in filteredChannels where !ids.contains(channel.teamId) { ids.append(channel.teamId) }
        if let preferred = config.teamsDefaultTeam, let index = ids.firstIndex(of: preferred) {
            ids.insert(ids.remove(at: index), at: 0)
        }
        return ids
    }
    var visibleBookmarks: [TeamsBookmark] {
        bookmarks.filter { bookmark in
            if case .collection(let name) = scope, bookmark.collection != name { return false }
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let text = [bookmark.title, bookmark.teamName, bookmark.channelName, bookmark.collection].joined(separator: " ")
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }.sorted { $0.savedAt > $1.savedAt }
    }
    var title: String {
        switch scope {
        case .saved: "Saved threads"
        case .following: "Following"
        case .collection(let name): name
        case .channel(let id): channels.first { $0.channelId == id }.map { "\($0.teamName) › \($0.channelName)" } ?? "Channel"
        case .team(let id): channels.first { $0.teamId == id }?.teamName ?? "Team"
        default: "All channels"
        }
    }
    var isBrowsing: Bool { browseMode }
    var selectedBookmark: TeamsBookmark? { bookmarks.first { $0.id == selectedHit?.key } }
    func bookmark(for hit: TeamsSearchHit) -> TeamsBookmark? { bookmarks.first { $0.id == hit.key } }

    func start() async {
        await loadChannels()
        await loadBookmarks()
        if scope != .all { reload() }
    }

    func stop() {
        feedTask?.cancel()
        threadTask?.cancel()
        generation = UUID()
        isLoadingFeed = false
        isLoadingThread = false
    }

    func loadChannels() async {
        guard service.isConfigured else {
            channelError = "Teams search is not configured. Set its connection in the managed profile."
            return
        }
        isLoadingChannels = true
        channelError = nil
        defer { isLoadingChannels = false }
        do {
            let loaded = try await service.channels().value
            guard !Task.isCancelled else { return }
            channels = loaded.channels.sorted {
                $0.teamName == $1.teamName
                    ? $0.channelName.localizedStandardCompare($1.channelName) == .orderedAscending
                    : $0.teamName.localizedStandardCompare($1.teamName) == .orderedAscending
            }
            if !defaultsRestored {
                let channel = UserDefaults.standard.string(forKey: "teams.channelFilter") ?? ""
                let savedTeam = UserDefaults.standard.string(forKey: "teams.teamFilter") ?? ""
                let team = UserDefaults.standard.bool(forKey: "teams.defaultsApplied") ? savedTeam : config.teamsDefaultTeam ?? savedTeam
                if channels.contains(where: { $0.channelId == channel }) { scope = .channel(channel) }
                else if !team.isEmpty, channels.contains(where: { $0.teamId == team }) { scope = .team(team) }
                if !team.isEmpty { expandedTeams.insert(team) }
                if case .channel(let id) = scope, let channel = channels.first(where: { $0.channelId == id }) {
                    expandedTeams.insert(channel.teamId)
                }
                if UserDefaults.standard.string(forKey: "teams.startingView") == "following" { scope = .following }
                else if UserDefaults.standard.string(forKey: "teams.startingView") == "saved" { scope = .saved }
                defaultsRestored = true
                UserDefaults.standard.set(true, forKey: "teams.defaultsApplied")
            }
        } catch {
            if !Task.isCancelled { channelError = error.localizedDescription }
        }
    }

    func loadBookmarks() async {
        bookmarkStore = nil
        bookmarks = []
        followedChannelIDs = []
        canSave = false
        do {
            let key = try await service.bookmarkAccountKey()
            guard !Task.isCancelled else { return }
            let root = URL(fileURLWithPath: NSString(string: AppEdition.current.supportDirectory).expandingTildeInPath)
                .appendingPathComponent("teams-bookmarks", isDirectory: true)
            let store = try TeamsBookmarkStore(directory: root, accountKey: key)
            bookmarks = try store.load()
            followedChannelIDs = Set(try store.loadFollowing())
            bookmarkStore = store
            bookmarkError = nil
            canSave = true
        } catch {
            if !Task.isCancelled { bookmarkError = error.localizedDescription }
        }
    }

    func scopeChanged() {
        closeThread()
        UserDefaults.standard.set(isFollowing ? "following" : isSaved ? "saved" : "channels", forKey: "teams.startingView")
        switch scope {
        case .team(let id):
            UserDefaults.standard.set(id, forKey: "teams.teamFilter")
            UserDefaults.standard.set("", forKey: "teams.channelFilter")
        case .channel(let id):
            UserDefaults.standard.set(id, forKey: "teams.channelFilter")
        case .all:
            UserDefaults.standard.set("", forKey: "teams.teamFilter")
            UserDefaults.standard.set("", forKey: "teams.channelFilter")
        default: break
        }
        reload()
    }

    func reload(loadMore: Bool = false) {
        guard let scope else { return }
        feedTask?.cancel()
        generation = UUID()
        let requestID = generation
        if !loadMore {
            hits = []
            total = 0
            nextOffset = nil
            indexVersion = nil
            hasLoadedFeed = false
            notice = nil
            closeThread()
        }
        feedError = nil
        guard !isSaved else { isLoadingFeed = false; return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var team: String?
        var channel: String?
        if case .team(let id) = scope { team = id }
        if case .channel(let id) = scope { channel = id }
        guard !isFollowing || !followedChannelIDs.isEmpty else { isLoadingFeed = false; return }
        guard isFollowing || !text.isEmpty || team != nil || channel != nil else { isLoadingFeed = false; return }
        guard service.isConfigured else { feedError = "Teams search is not configured."; return }
        let since = TeamsPeriod(rawValue: period)?.since
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = loadMore ? nextOffset ?? 0 : 0
        let previousVersion = indexVersion
        let following = isFollowing
        let followed = followedChannelIDs.sorted()
        browseMode = text.isEmpty
        isLoadingFeed = true
        UserDefaults.standard.set(self.author, forKey: "teams.author")
        UserDefaults.standard.set(period, forKey: "teams.period")
        feedTask = Task {
            defer { if generation == requestID { isLoadingFeed = false } }
            do {
                if text.isEmpty || following {
                    let page: TeamsBrowseResponse
                    if following {
                        page = try await service.followedFeed(channels: followed, query: text,
                                                              author: author.isEmpty ? nil : author,
                                                              since: since, limit: 30, offset: offset).value
                    } else {
                        page = try await service.browse(team: team, channel: channel,
                                                        author: author.isEmpty ? nil : author,
                                                        since: since, limit: 30, offset: offset).value
                    }
                    guard !Task.isCancelled, generation == requestID else { return }
                    if loadMore, let previousVersion, previousVersion != page.indexVersion {
                        reload()
                        notice = "The channel index refreshed. Showing the latest posts from the first page."
                        return
                    }
                    if loadMore {
                        var known = Set(hits.map(\.key))
                        hits += page.results.filter { known.insert($0.key).inserted }
                    } else { hits = page.results }
                    total = page.total
                    asOf = page.asOf
                    nextOffset = page.nextOffset
                    indexVersion = page.indexVersion
                } else {
                    let page = try await service.search(TeamsSearchQuery(text: text, team: team, channel: channel,
                                                                        author: author.isEmpty ? nil : author,
                                                                        since: since, limit: 100)).value
                    guard !Task.isCancelled, generation == requestID else { return }
                    hits = page.results
                    total = page.total
                    asOf = page.asOf
                    nextOffset = nil
                }
                hasLoadedFeed = true
            } catch {
                guard !Task.isCancelled, generation == requestID else { return }
                if text.isEmpty, let problem = error as? TeamsSearchError, problem == .notFound {
                    feedError = "Channel browsing is not available on this service yet. You can still search this channel above."
                } else { feedError = error.localizedDescription }
                hasLoadedFeed = true
            }
        }
    }

    func open(_ hit: TeamsSearchHit) {
        threadTask?.cancel()
        selectedHit = hit
        thread = nil
        threadError = nil
        isLoadingThread = true
        threadTask = Task {
            defer { if selectedHit?.key == hit.key { isLoadingThread = false } }
            do {
                let value = try await service.thread(id: hit.threadId, channel: hit.channelId).value
                guard !Task.isCancelled, selectedHit?.key == hit.key else { return }
                thread = value
            } catch {
                guard !Task.isCancelled, selectedHit?.key == hit.key else { return }
                threadError = error.localizedDescription
            }
        }
    }

    func closeThread() {
        threadTask?.cancel()
        selectedHit = nil
        thread = nil
        threadError = nil
        isLoadingThread = false
    }

    func save(_ hit: TeamsSearchHit, title: String, collection: String) throws {
        guard let bookmarkStore else { throw TeamsBookmarkStore.StoreError.invalidAccount }
        var updated = bookmarks.filter { $0.id != hit.key }
        updated.append(TeamsBookmark(hit: hit, title: title, collection: collection))
        try bookmarkStore.save(updated)
        bookmarks = updated
    }

    func remove(_ bookmark: TeamsBookmark) {
        guard let bookmarkStore else { return }
        do {
            let updated = bookmarks.filter { $0.id != bookmark.id }
            try bookmarkStore.save(updated)
            bookmarks = updated
            bookmarkError = nil
        } catch { bookmarkError = error.localizedDescription }
    }

    func toggleFollowing(_ channel: TeamsChannel) {
        guard let bookmarkStore else { return }
        var updated = followedChannelIDs
        if updated.contains(channel.channelId) { updated.remove(channel.channelId) }
        else { updated.insert(channel.channelId) }
        guard updated.count <= 500 else { bookmarkError = "You can follow up to 500 channels."; return }
        do {
            try bookmarkStore.saveFollowing(updated.sorted())
            followedChannelIDs = updated
            bookmarkError = nil
            if isFollowing { reload() }
        } catch { bookmarkError = error.localizedDescription }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
