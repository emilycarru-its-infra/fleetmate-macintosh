import SwiftUI
import FleetMateCore

/// Sheet for creating a new Azure DevOps work item.
struct CreateWorkItemView: View {
    let service: AzureDevOpsService
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var workItemType = "Bug"
    @State private var assignedTo = ""
    @State private var priority = 2
    @State private var tags = ""
    @State private var areaPath = ""
    @State private var iterationPath = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    // Picker data
    @State private var teamMembers: [IdentityRef] = []
    @State private var areaPaths: [String] = []
    @State private var iterationPaths: [String] = []

    private let workItemTypes = ["Bug", "Task", "User Story", "Feature", "Epic", "Issue"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New DevOps Work Item")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                TextField("Title", text: $title)

                Picker("Type", selection: $workItemType) {
                    ForEach(workItemTypes, id: \.self) { Text($0) }
                }

                Picker("Priority", selection: $priority) {
                    Text("1 - Critical").tag(1)
                    Text("2 - High").tag(2)
                    Text("3 - Medium").tag(3)
                    Text("4 - Low").tag(4)
                }

                if teamMembers.isEmpty {
                    TextField("Assigned To", text: $assignedTo)
                        .help("Email or display name")
                } else {
                    Picker("Assigned To", selection: $assignedTo) {
                        Text("Unassigned").tag("")
                        ForEach(teamMembers.indices, id: \.self) { i in
                            Text(teamMembers[i].displayName ?? teamMembers[i].uniqueName ?? "Unknown")
                                .tag(teamMembers[i].uniqueName ?? "")
                        }
                    }
                }

                if !areaPaths.isEmpty {
                    Picker("Area Path", selection: $areaPath) {
                        Text("Default").tag("")
                        ForEach(areaPaths, id: \.self) { Text($0).tag($0) }
                    }
                }

                if !iterationPaths.isEmpty {
                    Picker("Iteration", selection: $iterationPath) {
                        Text("Default").tag("")
                        ForEach(iterationPaths, id: \.self) { Text($0).tag($0) }
                    }
                }

                TextField("Tags", text: $tags)

                Section("Description") {
                    TextEditor(text: $description)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding()

            Divider()

            // Footer
            HStack {
                Text("⌘Enter to create")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Create") { createItem() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 500, height: 560)
        .task { loadPickerData() }
    }

    private func loadPickerData() {
        Task {
            do { teamMembers = try await service.getTeamMembers() } catch {
                dbg.debug("Create WI: team members load failed: \(error)", category: "azdo")
            }
        }
        Task {
            do { areaPaths = try await service.getAreaPaths() } catch {
                dbg.debug("Create WI: area paths load failed: \(error)", category: "azdo")
            }
        }
        Task {
            do { iterationPaths = try await service.getIterationPaths() } catch {
                dbg.debug("Create WI: iteration paths load failed: \(error)", category: "azdo")
            }
        }
    }

    private func createItem() {
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                let tagList: [String]? = tags.isEmpty ? nil :
                    tags.components(separatedBy: CharacterSet(charactersIn: ";,")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

                let request = CreateWorkItemRequest(
                    title: title.trimmingCharacters(in: .whitespaces),
                    type: workItemType,
                    description: description.isEmpty ? nil : description,
                    assignedTo: assignedTo.isEmpty ? nil : assignedTo,
                    priority: priority,
                    iterationPath: iterationPath.isEmpty ? nil : iterationPath,
                    areaPath: areaPath.isEmpty ? nil : areaPath,
                    tags: tagList
                )
                _ = try await service.createWorkItem(request)
                onCreated()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
