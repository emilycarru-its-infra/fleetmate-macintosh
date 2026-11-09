import AppKit
import FleetMateCore
import SwiftUI

struct TeamsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TeamsWorkspace(config: appState.config)
            .id((appState.config.teamsApiUrl ?? "") + "|" + (appState.config.teamsApiScope ?? "")
                + "|" + (appState.authManager.azAccount?.user ?? ""))
    }
}

private struct TeamsWorkspace: View {
    @StateObject private var model: TeamsWorkspaceModel
    @State private var saveDraft: TeamsSaveDraft?
    @AppStorage("teams.detailFraction") private var detailFraction = 0.5

    init(config: FleetMateConfig) {
        _model = StateObject(wrappedValue: TeamsWorkspaceModel(config: config))
    }

    var body: some View {
        HSplitView {
            TeamsChannelSidebar(model: model)
                .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)
            VStack(spacing: 0) {
                filters.fixedSize(horizontal: false, vertical: true)
                Divider()
                GeometryReader { geometry in
                    if geometry.size.width < 820, model.selectedHit != nil {
                        VStack(alignment: .leading, spacing: 0) {
                            Button("Back to Results", systemImage: "chevron.left", action: model.closeThread)
                                .padding(10)
                            reader
                        }
                    } else {
                        DetailSplitView(fraction: $detailFraction, showsDetail: model.selectedHit != nil,
                                        minLeading: 340, minTrailing: 400) {
                            feed
                        } trailing: { reader }
                    }
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tabSearch(text: $model.query, prompt: model.isSaved ? "Filter saved threads" : "Search Teams channels",
                   onSubmit: { model.reload() })
        .task { await model.start() }
        .onDisappear(perform: model.stop)
        .onChange(of: model.scope) { _, _ in model.scopeChanged() }
        .onChange(of: model.period) { _, _ in model.reload() }
        .onChange(of: model.query) { old, new in
            if !old.isEmpty && new.isEmpty { model.reload() }
        }
        .sheet(item: $saveDraft) { draft in
            TeamsSaveSheet(draft: draft, collections: model.collections) { title, collection in
                try model.save(draft.hit, title: title, collection: collection)
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(TeamsText.line(model.title)).font(.headline).lineLimit(1)
                if let channel = model.currentChannel {
                    Button(model.followedChannelIDs.contains(channel.channelId) ? "Following" : "Follow",
                           systemImage: model.followedChannelIDs.contains(channel.channelId) ? "star.fill" : "star") {
                        model.toggleFollowing(channel)
                    }
                    .controlSize(.small)
                    .disabled(!model.canSave)
                    .help(model.followedChannelIDs.contains(channel.channelId) ? "Unfollow this channel" : "Add this channel to Following")
                }
                Spacer(minLength: 6)
                if model.isLoadingFeed { ProgressView().controlSize(.small) }
                Button { model.reload() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Refresh this view")
            }
            if !model.isSaved {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { periodPicker; person.frame(width: 160); searchButton }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { periodPicker; searchButton }
                        person
                    }
                }
            }
            if model.isFollowing {
                Text("Newest activity first · \(model.followedChannelIDs.count) followed channels")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            if model.hasLoadedFeed {
                Text("\(model.total) threads" + (model.hits.count < model.total ? " · showing \(model.hits.count)" : "")
                     + (model.asOf.map { " · index as of \(TeamsDates.day($0) ?? $0)" } ?? ""))
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var periodPicker: some View {
        Picker("Period", selection: $model.period) {
            ForEach(TeamsPeriod.allCases) { period in Text(period.title).tag(period.rawValue) }
        }.fixedSize()
    }

    private var person: some View {
        TextField("Person", text: $model.author)
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.reload() }
            .help("Threads this person participated in")
    }

    private var searchButton: some View {
        Button("Search", systemImage: "magnifyingglass") { model.reload() }
            .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @ViewBuilder private var feed: some View {
        if model.isSaved {
            savedFeed
        } else if model.isFollowing && model.followedChannelIDs.isEmpty {
            ContentUnavailableView("Follow Your Channels", systemImage: "star",
                                   description: Text("Choose a channel on the left and click Follow. Its posts will appear here together with the other channels you follow, newest activity first."))
        } else if model.isLoadingFeed && model.hits.isEmpty {
            ProgressView(model.isBrowsing ? "Loading posts…" : "Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.feedError, model.hits.isEmpty {
            ContentUnavailableView {
                Label("Threads Unavailable", systemImage: "exclamationmark.bubble")
            } description: { Text(error) } actions: {
                Button("Try Again") { model.reload() }
            }
        } else if !model.hasLoadedFeed {
            ContentUnavailableView {
                Label("Find a Conversation", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Choose a channel on the left to browse recent posts, or search all channels above (⌘F). Save useful threads into collections to find them again.")
            } actions: {
                Button("Saved Threads") { model.scope = .saved }
            }
        } else if model.hits.isEmpty {
            ContentUnavailableView(model.isBrowsing ? "No Posts in This Period" : "No Matching Threads",
                                   systemImage: "bubble.left", description: Text("Try a wider period, another channel, or different search words."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                    if let error = model.feedError { Text(error).font(.callout).foregroundStyle(.secondary) }
                    ForEach(model.hits, id: \.key) { hit in
                        TeamsPostPreview(hit: hit, selected: model.selectedHit?.key == hit.key,
                                         saved: model.bookmark(for: hit) != nil, canSave: model.canSave,
                                         open: { model.open(hit) }, save: { editBookmark(hit) },
                                         copy: { model.copy(previewText(hit)) })
                    }
                    if model.nextOffset != nil {
                        Button(model.isLoadingFeed ? "Loading…" : "Load More Posts") { model.reload(loadMore: true) }
                            .disabled(model.isLoadingFeed)
                            .frame(maxWidth: .infinity)
                    }
                }.padding(16)
            }
        }
    }

    private var savedFeed: some View {
        Group {
            if model.visibleBookmarks.isEmpty {
                ContentUnavailableView("No Saved Threads", systemImage: "bookmark",
                                       description: Text(model.query.isEmpty ? "Use Save Thread on a post or conversation. Give it a useful name and a collection." : "No saved thread matches this filter."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.visibleBookmarks) { bookmark in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { model.open(bookmark.reference) } label: {
                                    Text(bookmark.title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Text("\(bookmark.teamName) › \(bookmark.channelName)").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Label(bookmark.collection.isEmpty ? "Saved threads" : bookmark.collection, systemImage: "folder")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Open Thread") { model.open(bookmark.reference) }
                                    Menu {
                                        Button("Edit Bookmark") { editBookmark(bookmark.reference) }
                                        Button("Remove Bookmark", role: .destructive) { model.remove(bookmark) }
                                    } label: { Label("Bookmark Actions", systemImage: "ellipsis").labelStyle(.iconOnly) }
                                }
                            }
                            .padding(14)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(16)
                }
            }
        }
    }

    private var reader: some View {
        TeamsConversationView(hit: model.selectedHit, thread: model.thread, isLoading: model.isLoadingThread,
                              error: model.threadError, linkHosts: model.linkHosts,
                              saved: model.selectedBookmark != nil, canSave: model.canSave,
                              copy: model.copy, save: { if let hit = model.selectedHit { editBookmark(hit) } },
                              retry: { if let hit = model.selectedHit { model.open(hit) } })
            .id(model.selectedHit?.key)
    }

    private func editBookmark(_ hit: TeamsSearchHit) {
        saveDraft = TeamsSaveDraft(hit: hit, existing: model.bookmark(for: hit))
    }

    private func previewText(_ hit: TeamsSearchHit) -> String {
        var text = hit.title + "\n" + TeamsText.body(hit.snippet)
        if let url = TeamsLinkPolicy.safeURL(hit.webUrl, allowedHosts: model.linkHosts) { text += "\nSource: " + url.absoluteString }
        return text
    }
}
