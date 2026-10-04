import SwiftUI
import FleetMateCore

/// Development › Skills: the shared skills, hooks and standards every
/// repository inherits, so what the agents are told to do is visible.
struct SkillsListView: View {
    @ObservedObject var knowledge: KnowledgeStore
    @Binding var selection: SkillCatalog.Entry?
    let filter: String

    private var grouped: [(SkillCatalog.Entry.Kind, [SkillCatalog.Entry])] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let entries = knowledge.skills.entries.filter {
            needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle)
                || $0.summary.localizedCaseInsensitiveContains(needle)
        }
        return SkillCatalog.Entry.Kind.allCases.compactMap { kind in
            let rows = entries.filter { $0.kind == kind }
            return rows.isEmpty ? nil : (kind, rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if knowledge.isSyncing { ProgressView().controlSize(.mini) }
                if let at = knowledge.skillsSyncedAt {
                    Text("Up to date with main · \(at.formatted(date: .omitted, time: .shortened))")
                } else if knowledge.isSkillsConfigured {
                    Text("Fetching the shared agents…")
                }
                Spacer()
            }
            .appFont(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            if !knowledge.isSkillsConfigured {
                ContentUnavailableView("No skills source",
                                       systemImage: "wand.and.stars",
                                       description: Text("Set agentsHubRepoUrl in FleetMate's settings profile."))
            } else if grouped.isEmpty {
                ContentUnavailableView("No skills yet", systemImage: "wand.and.stars",
                                       description: Text(knowledge.syncError ?? "They appear once the first fetch finishes."))
            } else {
                List(selection: Binding(get: { selection?.id }, set: { id in
                    selection = knowledge.skills.entries.first { $0.id == id }
                })) {
                    ForEach(grouped, id: \.0) { kind, rows in
                        Section(kind.rawValue) {
                            ForEach(rows) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).appFont(.body, weight: .medium)
                                    if !entry.summary.isEmpty {
                                        Text(entry.summary)
                                            .appFont(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 3)
                                .tag(entry.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

struct SkillDetailView: View {
    let entry: SkillCatalog.Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.name).appFont(.title2, weight: .semibold)
                    Text(entry.kind.rawValue.dropLast())
                        .appFont(.caption, weight: .medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Spacer()
                }
                Text(entry.path)
                    .appFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !entry.summary.isEmpty {
                    Text(entry.summary).appFont(.callout).foregroundStyle(.secondary)
                }
                if !entry.files.isEmpty {
                    HStack(spacing: 6) {
                        Text("Ships with").appFont(.caption).foregroundStyle(.secondary)
                        ForEach(entry.files, id: \.self) { file in
                            Text(file)
                                .appFont(.caption, design: .monospaced)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                if entry.kind == .skill {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        Text("In an agent session: /\(entry.name)")
                            .appFont(.callout, design: .monospaced)
                            .textSelection(.enabled)
                    }
                }
                Divider()
                MarkdownTextView(content: entry.body)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
