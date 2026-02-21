import SwiftUI
import FleetMateCore

/// Sheet for creating a new GitHub Projects v2 project.
struct CreateProjectView: View {
    let config: GitHubProviderConfig
    var onCreated: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var owner: String { config.organization ?? config.owner ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Project")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Name")
                        .font(.headline)
                    TextField("Enter project name", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                Text("Owner: \(owner)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding()

            Spacer()

            Divider()

            HStack {
                Spacer()
                Button("Create Project") { createProject() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 400, idealWidth: 450, minHeight: 250, idealHeight: 280)
    }

    private func createProject() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty, !owner.isEmpty else { return }
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

                // Determine scope and resolve owner ID accordingly
                let scope: ProjectScope
                switch config.projectScope.lowercased() {
                case "user": scope = .user
                case "repository", "repo": scope = .repository
                default: scope = .organization
                }
                let ownerId = try await service.getOwnerId(login: owner, scope: scope)
                _ = try await service.createProject(ownerId: ownerId, title: title.trimmingCharacters(in: .whitespaces))
                onCreated?()
                dismiss()
            } catch {
                errorMessage = "Failed: \(error.localizedDescription)"
            }
        }
    }
}
