import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FleetMateCore

/// Teams channel search: find a thread by what was said in it, read the whole
/// thread, and jump to it in Teams.
///
/// The toolbar search field (⌘F) runs the search; results are threads, not
/// single messages. The thread opens beside the list. Every result can be
/// opened in Teams, its link copied, or dragged out as a URL, and the thread's
/// text can be selected and copied like any other text. Message text is
/// people's own words: it is shown as data and never interpreted.
struct TeamsView: View {
    @EnvironmentObject var appState: AppState

    @State private var query = ""
    @State private var results: [TeamsSearchHit] = []
    @State private var total = 0
    @State private var asOf: String?
    @State private var channels: [TeamsChannel] = []
    @State private var selection: String?
    @State private var thread: TeamsThread?
    @State private var threadError: String?
    @State private var isSearching = false
    @State private var isLoadingThread = false
    @State private var searchError: String?
    @State private var hasSearched = false

    @AppStorage("teams.channelFilter") private var channelFilter = ""
    @AppStorage("teams.period") private var period = TeamsPeriod.anyTime.rawValue
    @AppStorage("teams.author") private var author = ""
    @AppStorage("teams.detailFraction") private var detailFraction = 0.5

    private var service: TeamsSearchService { TeamsSearchService(config: appState.config) }
    private var linkHosts: [String] { TeamsLinkPolicy.hosts(extra: appState.config.teamsLinkHosts) }

    private var selectedHit: TeamsSearchHit? {
        results.first { $0.key == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .tabSearch(text: $query, prompt: "Search Teams channels", onSubmit: runSearch)
        .task { await loadChannels() }
        .onChange(of: selection) { _, _ in loadThread() }
        .onChange(of: channelFilter) { _, _ in if hasSearched { runSearch() } }
        .onChange(of: period) { _, _ in if hasSearched { runSearch() } }
        .onCopyCommand { copyItems() }
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Channel", selection: $channelFilter) {
                Text("All channels").tag("")
                if !channels.isEmpty { Divider() }
                ForEach(channels, id: \.channelId) { channel in
                    Text("\(TeamsText.line(channel.teamName)) › \(TeamsText.line(channel.channelName))").tag(channel.channelId)
                }
            }
            .frame(maxWidth: 320)

            Picker("Period", selection: $period) {
                ForEach(TeamsPeriod.allCases) { p in Text(p.title).tag(p.rawValue) }
            }
            .frame(maxWidth: 200)

            TextField("Person", text: $author)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .onSubmit(runSearch)
                .help("Only threads this person took part in")

            Spacer()

            if isSearching {
                ProgressView().controlSize(.small)
            } else if hasSearched {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .appFont(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let count = total == 1 ? "1 thread" : "\(total) threads"
        guard let asOf, let day = TeamsDates.day(asOf) else { return count }
        return "\(count) · index as of \(day)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !service.isConfigured {
            ContentUnavailableView(
                "Teams Search Not Configured",
                systemImage: "gear.badge.xmark",
                description: Text("Set teams_api_url and teams_api_scope in the FleetMate config, or the managed profile's teamsApiUrl and teamsApiScope.")
            )
        } else if let searchError {
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.bubble",
                description: Text(searchError)
            )
        } else if !hasSearched {
            ContentUnavailableView(
                "Search Teams Channels",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Type in the search field (⌘F) and press Return to find threads in standard and shared channels.")
            )
        } else if results.isEmpty && !isSearching {
            ContentUnavailableView.search(text: query)
        } else {
            DetailSplitView(fraction: $detailFraction, showsDetail: selection != nil) {
                resultList
            } trailing: {
                TeamsThreadView(
                    linkHosts: linkHosts,
                    hit: selectedHit,
                    thread: thread,
                    isLoading: isLoadingThread,
                    error: threadError
                )
            }
        }
    }

    private var resultList: some View {
        List(results, id: \.key, selection: $selection) { hit in
            TeamsResultRow(hit: hit)
                .tag(hit.key)
                .contextMenu { resultMenu(hit) }
                .onDrag { dragProvider(hit) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { keys in
            if let key = keys.first, let hit = results.first(where: { $0.key == key }) { openInTeams(hit) }
        }
    }

    @ViewBuilder
    private func resultMenu(_ hit: TeamsSearchHit) -> some View {
        Button("Open in Teams") { openInTeams(hit) }
            .disabled(safeLink(hit) == nil)
        Button("Copy Link") { copyLink(hit) }
            .disabled(safeLink(hit) == nil)
        Divider()
        Button("Show Only This Channel") { channelFilter = hit.channelId }
        if let who = hit.authorDisplayName {
            Button("Threads with \(TeamsText.line(who))") {
                author = TeamsText.line(who)
                runSearch()
            }
        }
    }

    // MARK: Actions

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service.isConfigured, !text.isEmpty else { return }
        let request = TeamsSearchQuery(
            text: text,
            channel: channelFilter.isEmpty ? nil : channelFilter,
            author: author.trimmingCharacters(in: .whitespaces).isEmpty ? nil : author,
            since: TeamsPeriod(rawValue: period)?.since,
            limit: 100
        )
        let service = self.service
        isSearching = true
        searchError = nil
        Task {
            defer { isSearching = false }
            do {
                let response = try await service.search(request).value
                results = response.results
                total = response.total
                asOf = response.asOf
                hasSearched = true
                if !results.contains(where: { $0.key == selection }) { selection = results.first?.key }
            } catch {
                searchError = error.localizedDescription
                hasSearched = true
                results = []
            }
        }
    }

    private func loadChannels() async {
        guard service.isConfigured else { return }
        if let response = try? await service.channels().value {
            channels = response.channels.sorted {
                $0.teamName == $1.teamName
                    ? $0.channelName.localizedStandardCompare($1.channelName) == .orderedAscending
                    : $0.teamName.localizedStandardCompare($1.teamName) == .orderedAscending
            }
        }
    }

    private func loadThread() {
        guard let hit = selectedHit else {
            thread = nil
            return
        }
        let service = self.service
        isLoadingThread = true
        threadError = nil
        Task {
            defer { isLoadingThread = false }
            do {
                let loaded = try await service.thread(id: hit.threadId, channel: hit.channelId).value
                if selection == hit.key { thread = loaded }
            } catch {
                if selection == hit.key { threadError = error.localizedDescription }
            }
        }
    }

    /// The thread's link, only when it is https on an allowed host.
    private func safeLink(_ hit: TeamsSearchHit) -> URL? {
        TeamsLinkPolicy.safeURL(hit.webUrl, allowedHosts: linkHosts)
    }

    private func openInTeams(_ hit: TeamsSearchHit) {
        guard let url = safeLink(hit) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyLink(_ hit: TeamsSearchHit) {
        guard let url = safeLink(hit) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        board.setString("\(hit.title) — \(url.absoluteString)", forType: .string)
    }

    /// ⌘C on the list copies the selected thread's title and link.
    private func copyItems() -> [NSItemProvider] {
        guard let hit = selectedHit else { return [] }
        guard let url = safeLink(hit) else { return [NSItemProvider(object: hit.title as NSString)] }
        return [
            NSItemProvider(object: "\(hit.title) — \(url.absoluteString)" as NSString),
            NSItemProvider(object: url as NSURL),
        ]
    }

    private func dragProvider(_ hit: TeamsSearchHit) -> NSItemProvider {
        if let url = safeLink(hit) { return NSItemProvider(object: url as NSURL) }
        return NSItemProvider(object: hit.title as NSString)
    }
}

// MARK: - Rows

private struct TeamsResultRow: View {
    let hit: TeamsSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.title)
                    .appFont(.headline)
                    .lineLimit(1)
                Spacer()
                Text(TeamsDates.relative(hit.lastActivityAt))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(TeamsText.line(hit.teamName)) › \(TeamsText.line(hit.channelName))")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(TeamsText.body(hit.snippet))
                .appFont(.callout)
                .lineLimit(2)
            HStack(spacing: 10) {
                if let who = hit.authorDisplayName {
                    Label(TeamsText.line(who), systemImage: "person")
                }
                Label(hit.replyCount == 1 ? "1 reply" : "\(hit.replyCount) replies", systemImage: "arrowshape.turn.up.left")
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Thread

private struct TeamsThreadView: View {
    let linkHosts: [String]
    let hit: TeamsSearchHit?
    let thread: TeamsThread?
    let isLoading: Bool
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error {
                ContentUnavailableView("Thread Unavailable", systemImage: "exclamationmark.bubble", description: Text(error))
            } else if isLoading && thread == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let thread {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(thread.messages, id: \.messageId) { message in
                            TeamsMessageView(message: message, isReply: message.replyToId != nil, linkHosts: linkHosts)
                        }
                    }
                    .padding()
                    .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("No Thread Selected", systemImage: "bubble.left")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TeamsText.line(thread?.subject ?? hit?.title ?? "Thread"))
                    .appFont(.title3)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                if let hit {
                    Text("\(TeamsText.line(hit.teamName)) › \(TeamsText.line(hit.channelName))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let url = TeamsLinkPolicy.safeURL(thread?.webUrl ?? hit?.webUrl, allowedHosts: linkHosts) {
                Button("Open in Teams") { NSWorkspace.shared.open(url) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .help("Open this thread in Microsoft Teams (⇧⌘O)")
            }
        }
        .padding()
    }
}

private struct TeamsMessageView: View {
    let message: TeamsMessage
    let isReply: Bool
    let linkHosts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(TeamsText.line(message.authorDisplayName ?? "Unknown"))
                    .fontWeight(.semibold)
                Text(TeamsDates.full(message.createdAt))
                    .foregroundStyle(.secondary)
                if message.editedAt != nil {
                    Text("Edited").foregroundStyle(.secondary)
                }
            }
            .appFont(.caption)
            Text(TeamsText.body(message.text))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                // A link opens only when it is https on an allowed host;
                // anything else is shown as plain text.
                if let url = TeamsLinkPolicy.safeURL(attachment.url, allowedHosts: linkHosts) {
                    Link(destination: url) { Label(TeamsText.line(attachment.name), systemImage: "paperclip") }
                        .appFont(.caption)
                } else {
                    Label(TeamsText.line(attachment.name), systemImage: "paperclip")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, isReply ? 18 : 0)
        .overlay(alignment: .leading) {
            if isReply {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2)
            }
        }
    }
}

// MARK: - Helpers

enum TeamsPeriod: String, CaseIterable, Identifiable {
    case anyTime, lastMonth, lastQuarter, lastYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyTime: "Any time"
        case .lastMonth: "Last 30 days"
        case .lastQuarter: "Last 90 days"
        case .lastYear: "Last year"
        }
    }

    /// The `since` day for the API, or nil for any time.
    var since: String? {
        let days: Int
        switch self {
        case .anyTime: return nil
        case .lastMonth: days = 30
        case .lastQuarter: days = 90
        case .lastYear: days = 365
        }
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)
    }
}

enum TeamsDates {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func relative(_ value: String?) -> String {
        guard let date = parse(value) else { return "" }
        return date.formatted(.relative(presentation: .named))
    }

    static func full(_ value: String?) -> String {
        guard let date = parse(value) else { return value ?? "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func day(_ value: String) -> String? {
        if let date = parse(value) { return date.formatted(date: .abbreviated, time: .omitted) }
        return value.isEmpty ? nil : String(value.prefix(10))
    }
}

extension TeamsSearchHit {
    /// Thread ids are unique within a channel, not across channels.
    var key: String { "\(channelId)/\(threadId)" }
    var title: String {
        let subject = TeamsText.line(subject)
        if !subject.isEmpty { return subject }
        let first = TeamsText.line(snippet.split(separator: "\n").first.map(String.init) ?? snippet)
        return first.isEmpty ? "(no text)" : first
    }
}
