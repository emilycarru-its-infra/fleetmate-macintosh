import SwiftUI
import FleetMateCore

// MARK: - Result model

/// One hit from the dashboard's cross-system search. Everything comes from the
/// AppState caches, so scans are instant and never touch the network.
struct GlobalSearchResult: Identifiable, Hashable {
    enum Category: String, CaseIterable {
        case devices = "Devices"
        case inventory = "Inventory"
        case tickets = "Tickets"
        case workItems = "Work Items"
        case users = "Users"
        case groups = "Groups"

        var icon: String {
            switch self {
            case .devices:   return "laptopcomputer"
            case .inventory: return "shippingbox"
            case .tickets:   return "ticket"
            case .workItems: return "list.bullet.rectangle"
            case .users:     return "person"
            case .groups:    return "person.3"
            }
        }
    }

    let category: Category
    let id: String
    let title: String
    let subtitle: String
    /// Which field matched, so "why is this here?" is answered in the row.
    let matchLabel: String

    // Navigation payloads — whichever applies to the category.
    var deviceId: String?
    var ticketId: Int?
    var inventoryFilter: String?
}

// MARK: - Scanner

/// Pure in-memory fan-out over every cached system. Deliberately not a view or
/// a service: given the same caches and query it always returns the same rows.
@MainActor
enum GlobalSearchScanner {
    static let perCategoryLimit = 6

    static func search(_ rawQuery: String, appState: AppState) -> [GlobalSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return [] }

        var results: [GlobalSearchResult] = []
        results += devices(query, appState.cachedDevices)
        results += assets(query, appState.cachedAssets)
        results += tickets(query, appState.cachedTickets)
        results += workItems(query, appState.cachedWorkItems)
        results += users(query, appState.cachedEntraUsers)
        results += groups(query, appState.cachedGroups)
        return results
    }

    /// First matching (label, value) pair, so the row can say what matched.
    private static func firstMatch(_ query: String, _ fields: [(String, String?)]) -> (String, String)? {
        for (label, value) in fields {
            if let value, value.localizedCaseInsensitiveContains(query) {
                return (label, value)
            }
        }
        return nil
    }

    private static func devices(_ q: String, _ devices: [IntuneDevice]) -> [GlobalSearchResult] {
        devices.compactMap { device -> GlobalSearchResult? in
            guard let (label, value) = firstMatch(q, [
                ("Name", device.deviceName),
                ("Serial", device.serialNumber),
                ("User", device.userDisplayName),
                ("UPN", device.userPrincipalName),
                ("Model", device.model)
            ]) else { return nil }
            return GlobalSearchResult(
                category: .devices,
                id: "device-\(device.id)",
                title: device.deviceName ?? device.serialNumber ?? "(unnamed)",
                subtitle: [device.model, device.userDisplayName].compactMap { $0 }.joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                deviceId: device.id
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func assets(_ q: String, _ assets: [SnipeAsset]) -> [GlobalSearchResult] {
        assets.compactMap { asset -> GlobalSearchResult? in
            var fields: [(String, String?)] = [
                ("Name", asset.displayName),
                ("Serial", asset.serial),
                ("Tag", asset.assetTag),
                ("Allocation", asset.assignedTo?.name),
                ("Location", asset.rtdLocation?.name),
                ("Model", asset.model?.name)
            ]
            // Hostname, sharing name, fleet, … — whatever custom fields hold.
            for (name, field) in asset.customFields ?? [:] {
                fields.append((name, field.value))
            }
            guard let (label, value) = firstMatch(q, fields) else { return nil }
            return GlobalSearchResult(
                category: .inventory,
                id: "asset-\(asset.id)",
                title: asset.displayName ?? asset.assetTag ?? asset.serial ?? "(unnamed)",
                subtitle: [asset.model?.name, asset.assignedTo?.name ?? asset.rtdLocation?.name]
                    .compactMap { $0 }.joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                inventoryFilter: asset.serial ?? asset.assetTag ?? asset.displayName
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func tickets(_ q: String, _ tickets: [TdxTicket]) -> [GlobalSearchResult] {
        tickets.compactMap { ticket -> GlobalSearchResult? in
            guard let id = ticket.id else { return nil }
            guard let (label, value) = firstMatch(q, [
                ("ID", String(id)),
                ("Title", ticket.title),
                ("Requestor", ticket.requestorName)
            ]) else { return nil }
            return GlobalSearchResult(
                category: .tickets,
                id: "ticket-\(id)",
                title: ticket.title ?? "Ticket \(id)",
                subtitle: ["#\(id)", ticket.requestorName].compactMap { $0 }.joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                ticketId: id
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func workItems(_ q: String, _ items: [WorkItem]) -> [GlobalSearchResult] {
        items.compactMap { item -> GlobalSearchResult? in
            guard let (label, value) = firstMatch(q, [
                ("ID", String(item.id)),
                ("Title", item.fields?.title),
                ("Assigned", item.fields?.assignedTo?.displayName)
            ]) else { return nil }
            return GlobalSearchResult(
                category: .workItems,
                id: "wi-\(item.id)",
                title: item.fields?.title ?? "Work item \(item.id)",
                subtitle: ["#\(item.id)", item.fields?.state].compactMap { $0 }.joined(separator: " · "),
                matchLabel: "\(label): \(value)"
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func users(_ q: String, _ users: [EntraUser]) -> [GlobalSearchResult] {
        users.compactMap { user -> GlobalSearchResult? in
            guard let (label, value) = firstMatch(q, [
                ("Name", user.displayName),
                ("UPN", user.userPrincipalName)
            ]) else { return nil }
            return GlobalSearchResult(
                category: .users,
                id: "user-\(user.id ?? user.userPrincipalName ?? UUID().uuidString)",
                title: user.displayName ?? user.userPrincipalName ?? "(unnamed)",
                subtitle: user.userPrincipalName ?? "",
                matchLabel: "\(label): \(value)"
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func groups(_ q: String, _ groups: [EntraGroup]) -> [GlobalSearchResult] {
        groups.compactMap { group -> GlobalSearchResult? in
            guard let name = group.displayName,
                  name.localizedCaseInsensitiveContains(q) else { return nil }
            return GlobalSearchResult(
                category: .groups,
                id: "group-\(group.id ?? name)",
                title: name,
                subtitle: group.id ?? "",
                matchLabel: "Group name"
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }
}

// MARK: - Field

/// The dashboard's global search box. `large` is the front-and-center hero
/// variant; the default is compact for toolbar-like placements.
struct GlobalSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var large: Bool = false

    var body: some View {
        HStack(spacing: large ? 8 : 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .appFont(large ? .title3 : .callout)
            TextField("Search everything — serial, hostname, user, ticket…", text: $query)
                .textFieldStyle(.plain)
                .appFont(large ? .title3 : .body)
                .focused(focused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .appFont(large ? .title3 : .body)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, large ? 14 : 10)
        .padding(.vertical, large ? 10 : 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: large ? 12 : 8))
        .overlay(
            RoundedRectangle(cornerRadius: large ? 12 : 8)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: large ? .infinity : 280)
    }
}

// MARK: - Results panel

/// Floating grouped results, anchored under the field — MunkiStudio-style:
/// a top-trailing overlay over a tap-to-dismiss backdrop, dismissal is simply
/// clearing the query.
struct GlobalSearchResultsPanel: View {
    let results: [GlobalSearchResult]
    var width: CGFloat = 420
    let onSelect: (GlobalSearchResult) -> Void

    private var grouped: [(GlobalSearchResult.Category, [GlobalSearchResult])] {
        GlobalSearchResult.Category.allCases.compactMap { category in
            let hits = results.filter { $0.category == category }
            return hits.isEmpty ? nil : (category, hits)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(grouped, id: \.0) { category, hits in
                    HStack(spacing: 6) {
                        Image(systemName: category.icon)
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text(category.rawValue)
                            .appFont(.caption, weight: .semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(hits.count)")
                            .appFont(.caption2).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    ForEach(hits) { hit in
                        resultRow(hit)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(width: width)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    private func resultRow(_ hit: GlobalSearchResult) -> some View {
        Button {
            onSelect(hit)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .appFont(.callout, weight: .medium)
                        .lineLimit(1)
                    Spacer()
                    if !hit.subtitle.isEmpty {
                        Text(hit.subtitle)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(hit.matchLabel)
                    .appFont(.caption2, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
