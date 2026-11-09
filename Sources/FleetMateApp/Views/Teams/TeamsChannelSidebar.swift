import FleetMateCore
import SwiftUI

struct TeamsChannelSidebar: View {
    @ObservedObject var model: TeamsWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter teams and channels", text: $model.channelQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter teams and channels")
                if !model.channelQuery.isEmpty {
                    Button { model.channelQuery = "" } label: {
                        Label("Clear Channel Filter", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    }.buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .padding(10)
            HStack {
                Text(model.filteredChannels.count == 1 ? "1 channel" : "\(model.filteredChannels.count) channels").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.loadChannels() } } label: {
                    Label("Reload Channels", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }.buttonStyle(.borderless).disabled(model.isLoadingChannels)
            }.padding(.horizontal, 12).padding(.bottom, 8)
            if model.isLoadingChannels { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
            if let error = model.channelError {
                Text(error).font(.callout).foregroundStyle(.secondary).padding(10)
                Button("Try Again") { Task { await model.loadChannels() } }.padding(.horizontal, 10)
            }
            List(selection: $model.scope) {
                Label("All Channels", systemImage: "bubble.left.and.bubble.right")
                    .tag(TeamsWorkspaceModel.Scope.all)
                Section("Following") {
                    Label("All Followed Posts (\(model.followedChannelIDs.count))", systemImage: "star.fill")
                        .tag(TeamsWorkspaceModel.Scope.following)
                    ForEach(model.filteredChannels.filter { model.followedChannelIDs.contains($0.channelId) }, id: \.channelId) { channel in
                        row(channel)
                    }
                }
                Section("Your library") {
                    Label("Saved Threads (\(model.authorizedBookmarks.count))", systemImage: "bookmark")
                        .tag(TeamsWorkspaceModel.Scope.saved)
                    ForEach(model.collections, id: \.self) { name in
                        Label(name, systemImage: "folder").tag(TeamsWorkspaceModel.Scope.collection(name))
                    }
                }
                let pinned = model.filteredChannels.filter { model.config.preloadedTeamsChannelIDs.contains($0.channelId) }
                if !pinned.isEmpty {
                    Section("Preloaded") {
                        ForEach(pinned, id: \.channelId) { channel in row(channel) }
                    }
                }
                Section("Teams") {
                    ForEach(model.teamIDs, id: \.self) { teamID in
                        DisclosureGroup(isExpanded: expansion(teamID)) {
                            Label("Recent Team Posts", systemImage: "bubble.left")
                                .tag(TeamsWorkspaceModel.Scope.team(teamID))
                            ForEach(model.filteredChannels.filter { $0.teamId == teamID }, id: \.channelId) { channel in row(channel) }
                        } label: {
                            Text(TeamsText.line(model.channels.first { $0.teamId == teamID }?.teamName ?? "Team"))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            if model.filteredChannels.isEmpty && !model.channelQuery.isEmpty {
                Text("No channels match this filter.").font(.callout).foregroundStyle(.secondary).padding(12)
            }
            if let error = model.bookmarkError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Retry Saved Threads") { Task { await model.loadBookmarks() } }
                }.padding(10)
            }
        }
    }

    private func row(_ channel: TeamsChannel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(TeamsText.line(channel.channelName), systemImage: "number").lineLimit(1)
            Text(channel.threads == 1 ? "1 thread" : "\(channel.threads) threads")
                .font(.caption).foregroundStyle(.secondary)
        }
        .tag(TeamsWorkspaceModel.Scope.channel(channel.channelId))
        .help("\(TeamsText.line(channel.teamName)) › \(TeamsText.line(channel.channelName))")
        .contextMenu {
            Button(model.followedChannelIDs.contains(channel.channelId) ? "Unfollow Channel" : "Follow Channel",
                   systemImage: model.followedChannelIDs.contains(channel.channelId) ? "star.slash" : "star") {
                model.toggleFollowing(channel)
            }.disabled(!model.canSave)
        }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { !model.channelQuery.isEmpty || model.expandedTeams.contains(id) }, set: { expanded in
            if expanded { model.expandedTeams.insert(id) } else { model.expandedTeams.remove(id) }
        })
    }
}

struct TeamsSaveDraft: Identifiable {
    let hit: TeamsSearchHit
    let existing: TeamsBookmark?
    var id: String { hit.key }
}

struct TeamsSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: TeamsSaveDraft
    let collections: [String]
    let save: (String, String) throws -> Void
    @State private var title: String
    @State private var collection: String
    @State private var error: String?

    init(draft: TeamsSaveDraft, collections: [String], save: @escaping (String, String) throws -> Void) {
        self.draft = draft
        self.collections = collections
        self.save = save
        _title = State(initialValue: draft.existing?.title ?? String(draft.hit.title.prefix(240)))
        _collection = State(initialValue: draft.existing?.collection ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.existing == nil ? "Save Thread" : "Edit Bookmark").font(.title2).fontWeight(.semibold)
            Form {
                TextField("Name", text: $title)
                HStack {
                    TextField("Collection", text: $collection, prompt: Text("Saved threads"))
                    if !collections.isEmpty {
                        Menu("Choose") {
                            Button("Saved threads") { collection = "" }
                            ForEach(collections, id: \.self) { name in Button(name) { collection = name } }
                        }.fixedSize()
                    }
                }
            }
            Text("The bookmark saves its name, collection and thread reference. Opening it reloads the conversation.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try save(title, collection); dismiss() } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460)
    }
}
