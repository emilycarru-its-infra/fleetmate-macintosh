import SwiftUI
import FleetMateCore

struct UsersView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var searchResults: [EntraUser] = []
    @State private var isLoading = false
    @State private var selectedUser: EntraUser?
    @State private var pendingDisable: EntraUser?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Users")
                        .appFont(.largeTitle)
                        .fontWeight(.bold)
                    Text("Entra ID users")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search by email or name...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        searchUser()
                    }
                Button("Search") {
                    searchUser()
                }
                .disabled(searchText.isEmpty || isLoading)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Content
            if !appState.config.isGraphConfigured {
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("Microsoft Graph is not configured. Set GRAPH_TENANT_ID and GRAPH_CLIENT_ID in your config.")
                    )
                    Spacer()
                }
            } else if isLoading {
                VStack {
                    ProgressView("Searching...")
                        .padding(.top, 50)
                    Spacer()
                }
            } else if searchResults.isEmpty && !searchText.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "person.slash",
                        description: Text("No users found matching '\(searchText)'")
                    )
                    .padding(.top, 30)
                    Spacer()
                }
            } else if searchResults.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "Search for Users",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Enter an email address or name to search for users")
                    )
                    .padding(.top, 30)
                    Spacer()
                }
            } else {
                List(searchResults, id: \.id, selection: $selectedUser) { user in
                    UserRow(user: user)
                        .contextMenu {
                            if user.accountEnabled == true {
                                Button("Disable Account", role: .destructive) { pendingDisable = user }
                            } else {
                                Button("Enable Account") { setUser(user, enabled: true) }
                            }
                        }
                }
            }
        }
        .alert("Disable Account?", isPresented: Binding(
            get: { pendingDisable != nil },
            set: { if !$0 { pendingDisable = nil } }
        ), presenting: pendingDisable) { user in
            Button("Cancel", role: .cancel) { pendingDisable = nil }
            Button("Disable", role: .destructive) {
                setUser(user, enabled: false)
                pendingDisable = nil
            }
        } message: { user in
            Text("Disable \(user.userPrincipalName ?? user.displayName ?? "this user")? They will be unable to sign in.")
        }
    }

    private func setUser(_ user: EntraUser, enabled: Bool) {
        guard let identifier = user.userPrincipalName ?? user.id else {
            appState.errorMessage = "User has no UPN or id to act on"
            return
        }
        Task {
            do {
                try await appState.graphService.setUserAccountEnabled(identifier, enabled: enabled)
                searchUser() // refresh the row's state
            } catch {
                appState.errorMessage = "Failed to \(enabled ? "enable" : "disable") account: \(error.localizedDescription)"
            }
        }
    }

    private func searchUser() {
        guard appState.config.isGraphConfigured, !searchText.isEmpty else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                if let user = try await appState.graphService.getUser(searchText, includeGroups: true) {
                    searchResults = [user]
                } else {
                    searchResults = []
                }
            } catch {
                appState.errorMessage = "Failed to search users: \(error.localizedDescription)"
                searchResults = []
            }
        }
    }
}

struct UserRow: View {
    let user: EntraUser

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .appFont(.title)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName ?? "Unknown")
                        .appFont(.headline)
                    Text(user.userPrincipalName ?? user.mail ?? "-")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if user.accountEnabled == true {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .appFont(.caption)
                } else {
                    Label("Disabled", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .appFont(.caption)
                }
            }

            if user.jobTitle != nil || user.department != nil {
                HStack {
                    if let title = user.jobTitle {
                        Label(title, systemImage: "briefcase")
                            .appFont(.caption)
                    }
                    if let dept = user.department {
                        Label(dept, systemImage: "building.2")
                            .appFont(.caption)
                    }
                }
                .foregroundColor(.secondary)
            }

            if let groups = user.memberOf, !groups.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Groups (\(groups.count))")
                        .appFont(.caption)
                        .fontWeight(.semibold)
                    FlowLayout(spacing: 4) {
                        ForEach(groups.prefix(10), id: \.id) { group in
                            Text(group.displayName ?? "Unknown")
                                .appFont(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(4)
                        }
                        if groups.count > 10 {
                            Text("+\(groups.count - 10) more")
                                .appFont(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// Simple flow layout for group tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return layout(sizes: sizes, proposal: proposal).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let offsets = layout(sizes: sizes, proposal: proposal).offsets

        for (offset, subview) in zip(offsets, subviews) {
            subview.place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(sizes: [CGSize], proposal: ProposedViewSize) -> (offsets: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for size in sizes {
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            offsets.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, currentX)
        }

        return (offsets, CGSize(width: maxX, height: currentY + lineHeight))
    }
}

#Preview {
    UsersView()
        .environmentObject(AppState())
}
