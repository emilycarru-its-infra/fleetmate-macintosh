import SwiftUI

// MARK: - Filter Protocol

/// Protocol for module-specific filter category enums
protocol FilterCategoryProtocol: Hashable, CaseIterable, Identifiable, RawRepresentable where RawValue == String {}

// MARK: - Generic Filter State

/// Observable filter state that works across all modules.
/// Each module defines its own `FilterCategory` enum and extraction closure.
@MainActor
@Observable
class FilterState<Category: FilterCategoryProtocol> {
    var availableValues: [Category: [String]] = [:]
    var selectedValues: [Category: Set<String>] = [:]
    var selectedCategory: Category = Category.allCases.first! as! Category

    /// True if any filter is active
    var hasActiveFilters: Bool {
        selectedValues.values.contains { !$0.isEmpty }
    }

    /// True if a specific category has active selections
    func isActive(_ category: Category) -> Bool {
        !(selectedValues[category]?.isEmpty ?? true)
    }

    /// Count of active selections for a category
    func activeCount(_ category: Category) -> Int {
        selectedValues[category]?.count ?? 0
    }

    /// Toggle a value in a category
    func toggle(value: String, in category: Category) {
        if selectedValues[category] == nil { selectedValues[category] = [] }
        if selectedValues[category]!.contains(value) {
            selectedValues[category]!.remove(value)
        } else {
            selectedValues[category]!.insert(value)
        }
    }

    /// Clear all selections
    func clearAll() {
        selectedValues.removeAll()
    }

    /// Clear selections for a specific category
    func clear(_ category: Category) {
        selectedValues[category] = nil
    }
}

// MARK: - Filter Panel View (Shared Popover)

/// Two-column filter panel: categories on the left, checkbox values on the right.
/// Works with any module's FilterCategory enum via generics.
struct FilterPanelView<Category: FilterCategoryProtocol>: View {
    @Bindable var filters: FilterState<Category>
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Filters")
                    .appFont(.headline)
                Spacer()
                if filters.hasActiveFilters {
                    Button("Clear All") { filters.clearAll() }
                        .controlSize(.small)
                        .foregroundStyle(.yellow)
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Two-column split
            HStack(spacing: 0) {
                // Left: category tabs
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(Category.allCases), id: \.self) { category in
                            categoryRow(category)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
                .frame(width: 150)
                .background(Color.secondary.opacity(0.04))

                Divider()

                // Right: values for selected category
                VStack(spacing: 0) {
                    // Search within values
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .appFont(.caption)
                        TextField("Search...", text: $searchText)
                            .textFieldStyle(.plain)
                            .appFont(.caption)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.06))

                    Divider()

                    // Checkbox list of values
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredValues, id: \.self) { value in
                                valueRow(value)
                            }
                            if filteredValues.isEmpty {
                                Text("No matching values")
                                    .appFont(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(12)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(width: 460, height: 340)
        .onChange(of: filters.selectedCategory) { _, _ in searchText = "" }
    }

    // MARK: - Category Row

    private func categoryRow(_ category: Category) -> some View {
        Button(action: { filters.selectedCategory = category }) {
            HStack(spacing: 8) {
                Text(category.rawValue)
                    .appFont(fixed: 12, weight: filters.selectedCategory == category ? .semibold : .regular)
                    .foregroundStyle(filters.selectedCategory == category ? .primary : .secondary)
                Spacer()
                if filters.isActive(category) {
                    Text("\(filters.activeCount(category))")
                        .appFont(fixed: 10, weight: .bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(filters.selectedCategory == category ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Value Row

    private func valueRow(_ value: String) -> some View {
        let isSelected = filters.selectedValues[filters.selectedCategory]?.contains(value) ?? false
        return Button(action: { filters.toggle(value: value, in: filters.selectedCategory) }) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .appFont(fixed: 13)
                Text(value.htmlDecoded)
                    .appFont(fixed: 12)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filtered Values

    private var filteredValues: [String] {
        let all = filters.availableValues[filters.selectedCategory] ?? []
        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter { $0.lowercased().contains(query) }
    }
}
