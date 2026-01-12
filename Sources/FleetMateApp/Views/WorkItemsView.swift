import SwiftUI
import FleetMateCore

struct WorkItemsView: View {
    @EnvironmentObject var appState: AppState
    @State private var workItems: [WorkItem] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var filterState: String?

    var filteredItems: [WorkItem] {
        var result = workItems

        if let state = filterState {
            result = result.filter { $0.fields?.state?.lowercased() == state.lowercased() }
        }

        if !searchText.isEmpty {
            result = result.filter {
                ($0.fields?.title?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                "\($0.id)".contains(searchText)
            }
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Work Items")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Azure DevOps work items")
                        .foregroundColor(.secondary)
                }
                Spacer()

                Picker("State", selection: $filterState) {
                    Text("All").tag(nil as String?)
                    Text("Active").tag("Active" as String?)
                    Text("Resolved").tag("Resolved" as String?)
                    Text("Closed").tag("Closed" as String?)
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Button(action: loadWorkItems) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search work items...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Content
            if !appState.config.isDevOpsConfigured {
                ContentUnavailableView(
                    "Not Configured",
                    systemImage: "gear.badge.xmark",
                    description: Text("Azure DevOps is not configured. Set DEVOPS_ORGANIZATION and DEVOPS_PROJECT in your config.")
                )
            } else if isLoading {
                ProgressView("Loading work items...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Table(filteredItems) {
                    TableColumn("ID") { item in
                        Text("#\(item.id)")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Type") { item in
                        WorkItemTypeBadge(type: item.fields?.workItemType)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Title") { item in
                        Text(item.fields?.title ?? "-")
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("State") { item in
                        WorkItemStateBadge(state: item.fields?.state)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Priority") { item in
                        PriorityIndicator(priority: item.fields?.priority)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Assigned To") { item in
                        Text(item.fields?.assignedTo?.displayName ?? "-")
                    }
                    .width(min: 120, ideal: 150)
                }
            }
        }
        .task {
            if workItems.isEmpty {
                loadWorkItems()
            }
        }
    }

    private func loadWorkItems() {
        guard appState.config.isDevOpsConfigured else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                workItems = try await appState.devOpsService.getWorkItems(limit: 100)
            } catch {
                appState.errorMessage = "Failed to load work items: \(error.localizedDescription)"
            }
        }
    }
}

struct WorkItemTypeBadge: View {
    let type: String?

    var body: some View {
        let (color, icon): (Color, String) = {
            switch type?.lowercased() {
            case "bug": return (.red, "ladybug")
            case "task": return (.blue, "checkmark.square")
            case "user story": return (.purple, "person")
            case "feature": return (.green, "star")
            case "epic": return (.orange, "flag")
            default: return (.gray, "doc")
            }
        }()

        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(type ?? "Unknown")
                .font(.caption)
        }
    }
}

struct WorkItemStateBadge: View {
    let state: String?

    var body: some View {
        let color: Color = {
            switch state?.lowercased() {
            case "new", "active": return .blue
            case "resolved", "done": return .green
            case "closed": return .gray
            default: return .secondary
            }
        }()

        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state ?? "Unknown")
                .font(.caption)
        }
    }
}

struct PriorityIndicator: View {
    let priority: Int?

    var body: some View {
        let color: Color = {
            switch priority {
            case 1: return .red
            case 2: return .orange
            case 3: return .yellow
            case 4: return .green
            default: return .gray
            }
        }()

        HStack(spacing: 2) {
            ForEach(0..<(priority ?? 4), id: \.self) { _ in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

#Preview {
    WorkItemsView()
        .environmentObject(AppState())
}
