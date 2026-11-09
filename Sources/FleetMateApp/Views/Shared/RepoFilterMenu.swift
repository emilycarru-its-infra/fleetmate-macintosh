import SwiftUI
import FleetMateCore

/// Provider headings and project/owner submenus keep every repository filter consistent.
struct RepoFilterMenu: View {
    @Binding var selection: String?
    let entries: [RepositoryFilterEntry]

    private var selectedTitle: String {
        guard let selection else { return "All repositories" }
        return entries.first(where: { $0.id == selection })?.scope.displayPath
            ?? RepositoryFilterScope.displayKey(selection) ?? "All repositories"
    }

    private var selectedCount: Int? {
        guard let selection else { return nil }
        let matching = entries.filter { $0.scope.matches(selection, legacyKey: $0.legacyKey) }
        return matching.isEmpty ? nil : matching.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        Menu {
            Button { selection = nil } label: {
                if selection == nil { Label("All repositories", systemImage: "checkmark") }
                else { Text("All repositories") }
            }
            Divider()
            ForEach(RepositoryFilterProvider.groups(entries)) { provider in
                Section {
                    ForEach(provider.containers) { container in
                        Menu {
                            ForEach(container.entries) { entry in
                                Button { selection = entry.id } label: {
                                    let title = "\(entry.scope.repositoryTitle)  \(entry.count)"
                                    if let selection, entry.scope.matches(selection, legacyKey: entry.legacyKey) {
                                        Label(title, systemImage: "checkmark")
                                    } else { Text(title) }
                                }
                            }
                        } label: {
                            Label("\(container.name.isEmpty ? "Other" : container.name)  \(container.count)", systemImage: "folder")
                        }
                    }
                } header: {
                    Text("\(provider.source.displayName)  \(provider.count)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(selectedTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
                if let count = selectedCount {
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .appFont(.caption2, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("Filter by provider, project or owner, and repository")
    }
}

extension Array {
    /// Counts by key, busiest first, then by name. Empty when there is only
    /// one key — no choice to offer.
    func repoCounts(_ key: (Element) -> String) -> [(repo: String, count: Int)] {
        var counts: [String: Int] = [:]
        for element in self { counts[key(element), default: 0] += 1 }
        guard counts.count > 1 else { return [] }
        return counts.map { ($0.key, $0.value) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }
}
