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
    @State private var ownerKind: ProjectOwnerKind = .organization

    /// The organization (or configured owner) a non-personal project goes under.
    private var organizationOwner: String { config.organization ?? config.owner ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Project")
                    .appFont(.title2)
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
                        .appFont(.headline)
                    TextField("Enter project name", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Owner")
                        .appFont(.headline)
                    Picker("Owner", selection: $ownerKind) {
                        Text(organizationOwner.isEmpty ? "Organization" : "Organization (\(organizationOwner))")
                            .tag(ProjectOwnerKind.organization)
                        Text("Personal (your GitHub account)")
                            .tag(ProjectOwnerKind.personal)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .appFont(.caption)
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
        .frame(minWidth: 400, idealWidth: 450, minHeight: 290, idealHeight: 320)
        .onAppear {
            // Default to where the configured projects already live.
            if config.projectScope.lowercased() == "user" || organizationOwner.isEmpty { ownerKind = .personal }
        }
    }

    private func createProject() {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, ownerKind == .personal || !organizationOwner.isEmpty else { return }
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

                let ownerId: String
                switch ownerKind {
                case .personal:
                    ownerId = try await service.getViewer().id
                case .organization:
                    ownerId = try await service.getOwnerId(login: organizationOwner, scope: .organization)
                }
                _ = try await service.createProject(ownerId: ownerId, title: name)
                onCreated?()
                dismiss()
            } catch {
                errorMessage = "Failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Who owns a new GitHub project.
enum ProjectOwnerKind: Hashable {
    case organization
    case personal
}
