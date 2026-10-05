import SwiftUI

/// One dropdown for picking a repository, in place of a row of pills that
/// ran off the edge once there were more than a handful of repositories.
/// Busiest first, each with its count; "All repositories" clears it.
struct RepoFilterMenu: View {
    @Binding var selection: String?
    let counts: [(repo: String, count: Int)]

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                if selection == nil { Label("All repositories", systemImage: "checkmark") }
                else { Text("All repositories") }
            }
            Divider()
            ForEach(counts, id: \.repo) { entry in
                Button {
                    selection = entry.repo
                } label: {
                    let title = "\(entry.repo)  \(entry.count)"
                    if selection == entry.repo { Label(title, systemImage: "checkmark") }
                    else { Text(title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(selection ?? "All repositories")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let selection, let count = counts.first(where: { $0.repo == selection })?.count {
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .appFont(.caption2, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by repository")
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
