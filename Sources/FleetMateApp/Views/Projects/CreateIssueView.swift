import SwiftUI
import FleetMateCore

/// Sheet for creating a new GitHub Issue with full metadata support.
/// Mirrors GitHub's native issue creation dialog: title, markdown body,
/// assignees, labels, milestone, and project linkage.
struct CreateIssueView: View {
    let config: GitHubProviderConfig
    let projectId: String?
    let statusField: GitHubProjectField?
    var onCreated: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    // Form fields
    @State private var title = ""
    @State private var bodyText = ""
    @State private var showMarkdownPreview = false

    // Metadata selections
    @State private var selectedAssigneeIds: Set<String> = []
    @State private var selectedLabelIds: Set<String> = []
    @State private var selectedMilestoneId: String?
    @State private var selectedStatusOptionId: String?
    @State private var addToProject = true

    // Available options (loaded async)
    @State private var assignableUsers: [(id: String, login: String)] = []
    @State private var repoLabels: [(id: String, name: String, color: String?)] = []
    @State private var milestones: [(id: String, number: Int, title: String)] = []
    @State private var repositoryId: String?
    @State private var availableRepos: [(owner: String, name: String)] = []
    @State private var selectedRepo: String? = nil

    // State
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var owner: String { config.owner ?? config.organization ?? "" }
    private var repo: String {
        // Use selected repo from picker, or config repo
        selectedRepo ?? config.repo ?? ""
    }
    private var hasRepo: Bool { !owner.isEmpty && !repo.isEmpty }
    private var hasOwner: Bool { !owner.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Issue")
                    .appFont(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if isLoading {
                VStack {
                    ProgressView("Loading repository metadata...")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else if !hasOwner {
                VStack {
                    ContentUnavailableView(
                        "No Organization",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Set organization or owner in your GitHub config to create issues.")
                    )
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Repo picker when no repo in config
                        if config.repo == nil || config.repo?.isEmpty == true {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Repository")
                                    .appFont(.headline)
                                if availableRepos.isEmpty {
                                    Text("No repositories found for \(owner)")
                                        .foregroundColor(.secondary)
                                        .appFont(.caption)
                                } else {
                                    Picker("Repository", selection: $selectedRepo) {
                                        Text("Select a repository...").tag(nil as String?)
                                        ForEach(availableRepos, id: \.name) { r in
                                            Text(r.name).tag(r.name as String?)
                                        }
                                    }
                                    .labelsHidden()
                                    .onChange(of: selectedRepo) {
                                        // Reload metadata for newly selected repo
                                        Task { await loadMetadata() }
                                    }
                                }
                            }
                        }
                        // Title
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Title")
                                .appFont(.headline)
                            TextField("Issue title", text: $title)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Description with Markdown toggle
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Description")
                                    .appFont(.headline)
                                Spacer()
                                Picker("", selection: $showMarkdownPreview) {
                                    Text("Write").tag(false)
                                    Text("Preview").tag(true)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 160)
                            }

                            if showMarkdownPreview {
                                ScrollView {
                                    MarkdownTextView(content: markdownPreviewContent)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                                .frame(minHeight: 150, maxHeight: 250)
                                .background(Color.secondary.opacity(0.05))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.2))
                                )
                            } else {
                                TextEditor(text: $bodyText)
                                    .appFont(.body, design: .monospaced)
                                    .frame(minHeight: 150, maxHeight: 250)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.2))
                                    )
                            }

                            Text("Supports Markdown: **bold**, *italic*, `code`, [links](url), lists, headers")
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        // Metadata grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                            // Assignees
                            metadataSection("Assignees", icon: "person.2") {
                                if assignableUsers.isEmpty {
                                    Text("No assignable users")
                                        .foregroundColor(.secondary)
                                        .appFont(.caption)
                                } else {
                                    ForEach(assignableUsers, id: \.id) { user in
                                        Toggle(user.login, isOn: Binding(
                                            get: { selectedAssigneeIds.contains(user.id) },
                                            set: { if $0 { selectedAssigneeIds.insert(user.id) } else { selectedAssigneeIds.remove(user.id) } }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .appFont(.subheadline)
                                    }
                                }
                            }

                            // Labels
                            metadataSection("Labels", icon: "tag") {
                                if repoLabels.isEmpty {
                                    Text("No labels")
                                        .foregroundColor(.secondary)
                                        .appFont(.caption)
                                } else {
                                    FlowLayout(spacing: 6) {
                                        ForEach(repoLabels, id: \.id) { label in
                                            LabelChip(
                                                name: label.name,
                                                color: label.color,
                                                isSelected: selectedLabelIds.contains(label.id),
                                                onTap: {
                                                    if selectedLabelIds.contains(label.id) {
                                                        selectedLabelIds.remove(label.id)
                                                    } else {
                                                        selectedLabelIds.insert(label.id)
                                                    }
                                                }
                                            )
                                        }
                                    }
                                }
                            }

                            // Milestone
                            metadataSection("Milestone", icon: "flag") {
                                Picker("", selection: $selectedMilestoneId) {
                                    Text("None").tag(nil as String?)
                                    ForEach(milestones, id: \.id) { ms in
                                        Text(ms.title).tag(ms.id as String?)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }

                            // Project status
                            if projectId != nil, let sf = statusField {
                                metadataSection("Status", icon: "circle.grid.3x3") {
                                    Picker("", selection: $selectedStatusOptionId) {
                                        Text("None").tag(nil as String?)
                                        ForEach(sf.options, id: \.id) { opt in
                                            Text(opt.name).tag(opt.id as String?)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }
                            }
                        }

                        // Add to project toggle
                        if projectId != nil {
                            Toggle("Add to current project", isOn: $addToProject)
                                .appFont(.subheadline)
                        }
                    }
                    .padding()
                }

                Divider()

                // Footer
                HStack {
                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .appFont(.caption)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Create Issue") {
                        createIssue()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || !hasRepo || isCreating)
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 650)
        .task { await loadMetadata() }
    }

    // MARK: - Markdown Preview

    private var markdownPreviewContent: String {
        bodyText.isEmpty ? "*No content*" : bodyText
    }

    // MARK: - Metadata Section Builder

    @ViewBuilder
    private func metadataSection(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .appFont(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            content()
        }
    }

    // MARK: - Load Metadata

    private func loadMetadata() async {
        guard hasOwner else { return }
        isLoading = true
        defer { isLoading = false }

        let service = GitHubProjectsService(config: config)
        do {
            guard try await service.authenticate() else {
                errorMessage = "GitHub authentication failed"
                return
            }

            // Load available repos if not already in config
            if config.repo == nil || config.repo?.isEmpty == true {
                if availableRepos.isEmpty {
                    availableRepos = try await service.listOrganizationRepos(login: owner, limit: 50)
                }
                // Don't load metadata until a repo is selected
                guard hasRepo else { return }
            }

            async let repoId = service.getRepositoryId(owner: owner, name: repo)
            async let users = service.listAssignableUsers(owner: owner, name: repo)
            async let labels = service.listRepositoryLabels(owner: owner, name: repo)
            async let ms = service.listRepositoryMilestones(owner: owner, name: repo)

            repositoryId = try await repoId
            assignableUsers = try await users
            repoLabels = try await labels
            milestones = try await ms
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Create Issue

    private func createIssue() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let repoId = repositoryId else {
            errorMessage = "Repository not resolved"
            return
        }

        isCreating = true
        errorMessage = nil

        Task {
            defer { isCreating = false }

            let service = GitHubProjectsService(config: config)
            do {
                guard try await service.authenticate() else {
                    errorMessage = "Authentication failed"
                    return
                }

                let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = try await service.createIssue(
                    repositoryId: repoId,
                    title: title.trimmingCharacters(in: .whitespaces),
                    body: trimmedBody.isEmpty ? nil : trimmedBody,
                    assigneeIds: selectedAssigneeIds.isEmpty ? nil : Array(selectedAssigneeIds),
                    labelIds: selectedLabelIds.isEmpty ? nil : Array(selectedLabelIds),
                    milestoneId: selectedMilestoneId
                )

                // Add to project if requested
                if addToProject, let pid = projectId {
                    let itemId = try await service.addItemToProject(projectId: pid, contentId: result.id)

                    // Set status if selected
                    if let optionId = selectedStatusOptionId, let sf = statusField {
                        try await service.moveItemToStatus(
                            projectId: pid, itemId: itemId,
                            statusFieldId: sf.id, optionId: optionId
                        )
                    }
                }

                onCreated?()
                dismiss()
            } catch {
                errorMessage = "Failed to create issue: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Label Chip

private struct LabelChip: View {
    let name: String
    let color: String?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Text(name)
            .appFont(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(chipColor.opacity(isSelected ? 0.3 : 0.1))
            .foregroundColor(isSelected ? chipColor : .primary)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? chipColor : Color.clear, lineWidth: 1)
            )
            .onTapGesture { onTap() }
    }

    private var chipColor: Color {
        guard let hex = color else { return .secondary }
        return Color(hex: hex)
    }
}

// MARK: - Color Extension

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }
}
