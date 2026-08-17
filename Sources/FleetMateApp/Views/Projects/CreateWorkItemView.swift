import SwiftUI
import FleetMateCore

/// Sheet for creating a new Azure DevOps work item.
/// Board selection is first — valid work item types are derived from the board's column state mappings.
struct CreateWorkItemView: View {
    let service: AzureDevOpsService
    var boards: [Board] = []
    var boardColumnDefs: [BoardColumnDefinition] = []
    var preselectedBoard: String? = nil
    var boardProjectMap: [String: String] = [:]
    var boardTeamMap: [String: String] = [:]

    // Prefill values (for "Create New Alike")
    var prefillType: String? = nil
    var prefillAssignedTo: String? = nil
    var prefillPriority: Int? = nil
    var prefillAreaPath: String? = nil
    var prefillIterationPath: String? = nil
    var prefillTags: String? = nil
    var prefillDescription: String? = nil

    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var workItemType = ""
    @State private var assignedTo = ""
    @State private var priority = 2
    @State private var tags = ""
    @State private var areaPath = ""
    @State private var iterationPath = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    // Board selection
    @State private var selectedBoard: String? = nil
    @State private var localBoards: [Board] = []
    @State private var localColumnDefs: [BoardColumnDefinition] = []
    @State private var isLoadingBoards = false
    @State private var allowedTypes: [String] = []

    // Picker data
    @State private var teamMembers: [IdentityRef] = []
    @State private var areaPaths: [String] = []
    @State private var iterationPaths: [String] = []

    private static let fallbackTypes: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New DevOps Work Item")
                    .appFont(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                // Board selection — first
                if isLoadingBoards {
                    HStack {
                        Text("Loading boards…")
                            .foregroundColor(.secondary)
                        ProgressView().controlSize(.small)
                    }
                } else if !localBoards.isEmpty {
                    Picker("Board", selection: $selectedBoard) {
                        Text("Select board…").tag(nil as String?)
                        ForEach(localBoards) { board in
                            Text(board.name ?? "Unknown").tag(board.name as String?)
                        }
                    }
                    .onChange(of: selectedBoard) { _, newBoard in
                        loadBoardTypes(boardName: newBoard)
                    }
                }

                // Type — derived from board
                if !allowedTypes.isEmpty {
                    Picker("Type", selection: $workItemType) {
                        ForEach(allowedTypes, id: \.self) { Text($0) }
                    }
                } else if selectedBoard != nil {
                    HStack {
                        Text("Type")
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
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

                // Title sits directly above the description, echoing the ADO
                // work item editor.
                TextField("Title", text: $title)

                Section("Description") {
                    TextEditor(text: $description)
                        .appFont(.body, design: .monospaced)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 120)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                    Text("Markdown supported")
                        .appFont(.caption2)
                        .foregroundColor(.secondary)
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .appFont(.caption)
                }
            }
            .padding()

            Divider()

            // Footer
            HStack {
                Text("⌘Enter to create")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Create") { createItem() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || workItemType.isEmpty || isCreating)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 500, height: 620)
        .task { loadPickerData() }
    }

    private func loadPickerData() {
        // Apply prefill values
        if let p = prefillPriority { priority = p }
        if let p = prefillAssignedTo { assignedTo = p }
        if let p = prefillAreaPath { areaPath = p }
        if let p = prefillIterationPath { iterationPath = p }
        if let p = prefillTags { tags = p }
        if let p = prefillDescription { description = p }

        // Use passed-in boards or load fresh
        if !boards.isEmpty {
            localBoards = boards
            if let pre = preselectedBoard {
                selectedBoard = pre
                // Use passed-in column defs if they match the preselected board
                if !boardColumnDefs.isEmpty {
                    extractTypesFromColumns(boardColumnDefs)
                } else {
                    loadBoardTypes(boardName: pre)
                }
            }
        } else {
            isLoadingBoards = true
            Task {
                defer { isLoadingBoards = false }
                do {
                    localBoards = try await service.getBoards()
                    if let first = localBoards.first?.name {
                        selectedBoard = first
                        loadBoardTypes(boardName: first)
                    }
                } catch {
                    await loadWorkItemTypesAsFallback()
                    dbg.debug("Create WI: boards load failed: \(error)", category: "azdo")
                }
            }
        }

        Task {
            do { teamMembers = try await service.getProjectMembers() } catch {
                dbg.debug("Create WI: project members load failed: \(error)", category: "azdo")
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

    private func loadBoardTypes(boardName: String?) {
        guard let boardName = boardName else {
            allowedTypes = []
            workItemType = ""
            return
        }
        Task {
            do {
                let team = boardTeamMap[boardName]
                let project = boardProjectMap[boardName]
                let columns: [BoardColumnDefinition]
                if let team = team {
                    columns = try await service.getBoardColumns(boardName: boardName, team: team, project: project)
                } else {
                    columns = try await service.getBoardColumns(boardName: boardName, project: project)
                }
                localColumnDefs = columns
                extractTypesFromColumns(columns)
            } catch {
                await loadWorkItemTypesAsFallback()
                dbg.debug("Create WI: columns load failed for board '\(boardName)': \(error)", category: "azdo")
            }
        }
    }

    /// Extract unique work item types from column state mappings.
    private func extractTypesFromColumns(_ columns: [BoardColumnDefinition]) {
        var types = Set<String>()
        for col in columns {
            if let mappings = col.stateMappings {
                types.formUnion(mappings.keys)
            }
        }
        let sorted = types.sorted()
        allowedTypes = sorted
        // Apply prefill type if valid, otherwise auto-select first
        if let prefill = prefillType, allowedTypes.contains(prefill) {
            workItemType = prefill
        } else if !allowedTypes.contains(workItemType), let first = allowedTypes.first {
            workItemType = first
        }
    }

    /// Query the project’s process template for valid work item types when board columns aren’t available.
    private func loadWorkItemTypesAsFallback() async {
        do {
            let types = try await service.getWorkItemTypes()
            allowedTypes = types.map(\.name).sorted()
        } catch {
            dbg.debug("Create WI: work item types fallback failed: \(error)", category: "azdo")
        }
        if let prefill = prefillType, allowedTypes.contains(prefill) {
            workItemType = prefill
        } else if !allowedTypes.contains(workItemType), let first = allowedTypes.first {
            workItemType = first
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
