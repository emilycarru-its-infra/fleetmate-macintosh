import Foundation

// MARK: - Board columns

/// One status column of a GitHub Projects v2 board.
public struct GitHubProjectBoardColumn: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    /// The option's colour name as GitHub reports it (GRAY, BLUE, GREEN, …).
    public let color: String?
    public var items: [GitHubProjectItem]

    public init(name: String, color: String? = nil, items: [GitHubProjectItem] = []) {
        self.name = name
        self.color = color
        self.items = items
    }
}

/// Groups project items into the columns of the project's Status field, the way
/// GitHub's own board view lays them out.
public enum GitHubProjectBoard {
    /// Column for items whose Status is unset or names an option that no longer exists.
    public static let noStatus = "No Status"

    /// Columns in the Status field's option order, then "No Status" when any
    /// item lands there. `search` narrows by title, number and repository.
    public static func columns(
        items: [GitHubProjectItem],
        statusField: GitHubProjectField?,
        search: String = ""
    ) -> [GitHubProjectBoardColumn] {
        var columns = (statusField?.options ?? []).map {
            GitHubProjectBoardColumn(name: $0.name, color: $0.color)
        }
        var unsorted: [GitHubProjectItem] = []

        for item in items where item.matches(search: search) {
            if let status = item.statusName,
               let index = columns.firstIndex(where: { $0.name.caseInsensitiveCompare(status) == .orderedSame }) {
                columns[index].items.append(item)
            } else {
                unsorted.append(item)
            }
        }

        if !unsorted.isEmpty {
            columns.append(GitHubProjectBoardColumn(name: noStatus, items: unsorted))
        }
        return columns
    }
}

// MARK: - Item helpers

extension GitHubProjectItem {
    /// The issue/PR title, or the draft's title.
    public var displayTitle: String {
        content?.title ?? draftContent?.title ?? "Untitled"
    }

    /// The item's single-select Status value, if set.
    public var statusName: String? {
        fieldValues.first { $0.fieldName.caseInsensitiveCompare("Status") == .orderedSame }?.singleSelectValue
    }

    public var isDraft: Bool { type == "DRAFT_ISSUE" }

    func matches(search: String) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        if displayTitle.localizedCaseInsensitiveContains(needle) { return true }
        if let content {
            let number = needle.hasPrefix("#") ? String(needle.dropFirst()) : needle
            if String(content.number) == number { return true }
            if content.repository?.localizedCaseInsensitiveContains(needle) == true { return true }
        }
        return false
    }
}
