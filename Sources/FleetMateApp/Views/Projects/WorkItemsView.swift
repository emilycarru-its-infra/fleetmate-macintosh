import SwiftUI
import FleetMateCore

struct WorkItemsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var filterState: String?

    // Use cached work items from appState
    var workItems: [WorkItem] { appState.cachedWorkItems }

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
                    Text("Tasks")
                        .appFont(.largeTitle)
                        .fontWeight(.bold)
                    Text("Tasks from DevOps, Planner, GitHub, etc.")
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
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("Azure DevOps is not configured. Set DEVOPS_ORGANIZATION and DEVOPS_PROJECT in your config.")
                    )
                    Spacer()
                }
            } else if isLoading {
                VStack {
                    ProgressView("Loading work items...")
                        .padding(.top, 50)
                    Spacer()
                }
            } else if filteredItems.isEmpty {
                VStack {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 30)
                    Spacer()
                }
            } else {
                Table(filteredItems) {
                    TableColumn("ID") { item in
                        Text("#\(item.id)")
                            .appFont(.body, design: .monospaced)
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
            if !appState.isWorkItemsCacheValid {
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
                let items = try await appState.devOpsService.getWorkItems(limit: 100)
                appState.updateWorkItemsCache(items)
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
                .appFont(.caption)
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
                .appFont(.caption)
        }
    }
}

struct PriorityIndicator: View {
    let priority: Int?

    var body: some View {
        let p = priority ?? 4
        let color: Color = {
            switch p {
            case 1: return .red
            case 2: return .orange
            case 3: return .yellow
            case 4: return .green
            default: return .gray
            }
        }()
        let filled = max(0, 5 - p) // 1→4 filled, 2→3, 3→2, 4→1

        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i < filled ? color : color.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

#Preview {
    WorkItemsView()
        .environmentObject(AppState())
}
