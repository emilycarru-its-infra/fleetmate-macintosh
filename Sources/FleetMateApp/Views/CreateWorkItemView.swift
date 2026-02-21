import SwiftUI
import FleetMateCore

/// Sheet for creating a new Azure DevOps work item.
struct CreateWorkItemView: View {
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var workItemType = "Bug"
    @State private var assignedTo = ""
    @State private var priority = 2
    @State private var tags = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

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

                TextField("Assigned To", text: $assignedTo)
                    .help("Email or display name")

                TextField("Tags (semicolon-separated)", text: $tags)

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
                Spacer()
                Button("Create") { createItem() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
    }

    private func createItem() {
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                let config = try FleetMateConfig.load()
                let service = AzureDevOpsService(config: config)

                let tagList: [String]? = tags.isEmpty ? nil :
                    tags.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

                let request = CreateWorkItemRequest(
                    title: title.trimmingCharacters(in: .whitespaces),
                    type: workItemType,
                    description: description.isEmpty ? nil : description,
                    assignedTo: assignedTo.isEmpty ? nil : assignedTo,
                    priority: priority,
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
