import SwiftUI
import AppKit
import FleetMateCore

/// Pick a library command or type one, see its trust, and run it on the
/// selected online machines. Caution and destructive commands confirm
/// first; placeholders prompt for their values.
struct CommandToolbar: View {
    @ObservedObject var manage: ManageState
    @State private var showAddSheet = false
    @State private var showEditSheet = false
    @State private var showHistoryPopover = false
    @State private var placeholderTemplate: PlaceholderTemplate?
    @State private var pendingRun: PendingRun?

    /// A run waiting on the operator's confirmation.
    struct PendingRun: Identifiable {
        let id = UUID()
        let label: String
        let script: String
        let trust: CommandTrustLevel
        let recordHistory: Bool
    }

    private var selectedCount: Int { manage.selectedComputerIDs.count }
    private var selectedOnlineCount: Int { manage.onlineSelectedComputers.count }

    private var canRun: Bool {
        !manage.isRunning && !manage.resolvedCommandString.isEmpty && selectedOnlineCount > 0
    }

    private var runDisabledReason: String {
        if manage.resolvedCommandString.isEmpty { return "Choose a command or type one." }
        if selectedCount == 0 { return "Select at least one machine." }
        if selectedOnlineCount == 0 { return "The selected machines are offline." }
        if manage.isRunning { return "A run is already in progress." }
        return "Run on the selected online machines"
    }

    var body: some View {
        VStack(spacing: 8) {
            pickersRow
            commandRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .sheet(isPresented: $showEditSheet) {
            if let categoryID = manage.selectedCategoryID, let command = manage.selectedCommand {
                CommandEditorSheet(manage: manage, mode: .edit(categoryID: categoryID, command: command), isPresented: $showEditSheet)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            CommandEditorSheet(manage: manage, mode: .add(defaultCategoryID: manage.selectedCategoryID), isPresented: $showAddSheet)
        }
        .sheet(item: $placeholderTemplate) { template in
            PlaceholderSheet(template: template) { resolved in
                let trust = manage.selectedCommand?.trustLevel ?? CommandTrustLevel.inferred(from: resolved)
                requestRun(label: template.label, script: resolved, trust: trust, recordHistory: !template.hasSensitive)
            }
        }
        .confirmationDialog(
            pendingRun.map { "\($0.trust.warningTitle) \($0.label)" } ?? "Run command?",
            isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } }),
            titleVisibility: .visible
        ) {
            if let run = pendingRun {
                Button("Run on \(selectedOnlineCount) machine\(selectedOnlineCount == 1 ? "" : "s")", role: run.trust == .destructive ? .destructive : nil) {
                    manage.runQuickCommand(run.script, label: run.label, recordHistory: run.recordHistory)
                    pendingRun = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRun = nil }
        } message: {
            if let run = pendingRun { Text(run.trust.warningMessage) }
        }
    }

    // MARK: - Rows

    private var pickersRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { manage.selectedCategoryID },
                set: { manage.selectedCategoryID = $0; manage.selectedCommandID = nil; manage.customCommand = "" }
            )) {
                Text("Category").tag(nil as UUID?)
                ForEach(manage.commandCategories) { category in
                    Text(category.name).tag(category.id as UUID?)
                }
            }
            .frame(width: 160)
            .disabled(manage.commandCategories.isEmpty)

            Picker("", selection: Binding(
                get: { manage.selectedCommandID },
                set: { manage.selectedCommandID = $0; manage.customCommand = "" }
            )) {
                Text("Command").tag(nil as UUID?)
                if let category = manage.selectedCategory {
                    ForEach(category.commands) { command in
                        Text(command.label).tag(command.id as UUID?)
                    }
                }
            }
            .frame(minWidth: 180, maxWidth: 280)
            .disabled(manage.selectedCategory == nil)

            if let command = manage.selectedCommand {
                TrustBadge(level: command.trustLevel)
                Text(command.command)
                    .appFont(.footnote, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(command.command)
            } else {
                Spacer()
            }

            Button { showEditSheet = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .disabled(manage.selectedCommand == nil)
                .help("Edit the selected command")
            Button { showAddSheet = true } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add a command to the library")
        }
    }

    private var commandRow: some View {
        HStack(spacing: 8) {
            TextEditor(text: $manage.customCommand)
                .appFont(.subheadline, design: .monospaced)
                .frame(minHeight: 42, idealHeight: 54, maxHeight: 72)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
                .overlay(alignment: .topLeading) {
                    if manage.customCommand.isEmpty {
                        Text("or type a command…")
                            .appFont(.subheadline, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: manage.customCommand) { _, value in
                    if !value.isEmpty { manage.selectedCommandID = nil }
                }

            Button { showHistoryPopover = true } label: { Image(systemName: "clock") }
                .buttonStyle(.borderless)
                .help("Command history")
                .popover(isPresented: $showHistoryPopover, arrowEdge: .bottom) {
                    CommandHistoryPopover(manage: manage, isPresented: $showHistoryPopover)
                }

            if manage.isRunning {
                Button {
                    manage.killCommand()
                } label: {
                    Label("Kill", systemImage: "stop.fill").frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.manageFailure)
            }

            Button {
                runRequested()
            } label: {
                Label("Run", systemImage: "play.fill").frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
            .help(canRun ? "Run on the selected online machines" : runDisabledReason)
            .keyboardShortcut(.return, modifiers: .command)

            if selectedCount == 0 {
                Text("Select machines").appFont(.caption2).foregroundStyle(.secondary)
            } else {
                Text("\(selectedOnlineCount)/\(selectedCount) online")
                    .appFont(.caption2)
                    .foregroundStyle(selectedOnlineCount == selectedCount ? Color.secondary : Color.manageWarning)
            }
        }
    }

    // MARK: - Run flow

    private func runRequested() {
        let script = manage.resolvedCommandString
        guard !script.isEmpty else { return }
        let label = manage.selectedCommand?.label ?? script
        if let template = PlaceholderTemplate.detect(label: label, command: script) {
            placeholderTemplate = template
            return
        }
        let trust = manage.selectedCommand?.trustLevel ?? CommandTrustLevel.inferred(from: script)
        requestRun(label: label, script: script, trust: trust, recordHistory: true)
    }

    private func requestRun(label: String, script: String, trust: CommandTrustLevel, recordHistory: Bool) {
        if trust == .safe {
            manage.runQuickCommand(script, label: label, recordHistory: recordHistory)
        } else {
            pendingRun = PendingRun(label: label, script: script, trust: trust, recordHistory: recordHistory)
        }
    }
}

struct TrustBadge: View {
    let level: CommandTrustLevel

    var body: some View {
        StatusCapsule(text: level.label, systemImage: icon, tint: tint)
            .help(level.warningMessage)
    }

    private var icon: String {
        switch level {
        case .safe: "checkmark.shield"
        case .caution: "exclamationmark.triangle"
        case .destructive: "exclamationmark.octagon"
        }
    }

    private var tint: Color {
        switch level {
        case .safe: .manageSuccess
        case .caution: .manageWarning
        case .destructive: .manageFailure
        }
    }
}

// MARK: - Placeholders

struct PlaceholderSheet: View {
    let template: PlaceholderTemplate
    let onRun: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Command Values").appFont(.headline)
            Text(template.label).appFont(.subheadline, weight: .medium).foregroundStyle(.secondary)

            ForEach(template.placeholders, id: \.self) { placeholder in
                VStack(alignment: .leading, spacing: 5) {
                    Text(PlaceholderTemplate.fieldLabel(placeholder)).appFont(.caption).foregroundStyle(.secondary)
                    if PlaceholderTemplate.isSensitive(placeholder) {
                        SecureField(placeholder, text: binding(placeholder)).textFieldStyle(.roundedBorder)
                    } else {
                        TextField(placeholder, text: binding(placeholder)).textFieldStyle(.roundedBorder)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Resolved command").appFont(.caption).foregroundStyle(.secondary)
                Text(template.resolve(values, redactSensitive: true))
                    .appFont(.footnote, design: .monospaced)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run") {
                    onRun(template.resolve(values))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!template.isComplete(values))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func binding(_ placeholder: String) -> Binding<String> {
        Binding(get: { values[placeholder] ?? "" }, set: { values[placeholder] = $0 })
    }
}

// MARK: - Editor

enum CommandEditorMode {
    case add(defaultCategoryID: UUID?)
    case edit(categoryID: UUID, command: ManageCommand)
}

struct CommandEditorSheet: View {
    @ObservedObject var manage: ManageState
    let mode: CommandEditorMode
    @Binding var isPresented: Bool

    @State private var label = ""
    @State private var commandText = ""
    @State private var trustLevel: CommandTrustLevel = .safe
    @State private var selectedCategoryID: UUID?
    @State private var newCategoryName = ""
    @State private var isCreatingCategory = false
    @State private var confirmDelete = false

    private static let newCategorySentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private var isAddMode: Bool { if case .add = mode { return true }; return false }

    private var canSave: Bool {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty,
              !commandText.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isAddMode {
            if isCreatingCategory { return !newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty }
            return selectedCategoryID != nil && selectedCategoryID != Self.newCategorySentinel
        }
        return true
    }

    private var inferred: CommandTrustLevel { CommandTrustLevel.inferred(from: commandText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isAddMode ? "Add Command" : "Edit Command").appFont(.headline)

            if isAddMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Category").appFont(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("", selection: $selectedCategoryID) {
                            ForEach(manage.commandCategories) { category in
                                Text(category.name).tag(category.id as UUID?)
                            }
                            Divider()
                            Text("New category…").tag(Self.newCategorySentinel as UUID?)
                        }
                        .frame(minWidth: 180)
                        .onChange(of: selectedCategoryID) { _, value in
                            isCreatingCategory = value == Self.newCategorySentinel
                        }
                        if isCreatingCategory {
                            TextField("Category name", text: $newCategoryName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Label").appFont(.caption).foregroundStyle(.secondary)
                TextField("e.g. Restart Munki", text: $label).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command").appFont(.caption).foregroundStyle(.secondary)
                TextEditor(text: $commandText)
                    .appFont(.subheadline, design: .monospaced)
                    .frame(minHeight: 72, maxHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("Use <PLACEHOLDER> tokens for values to prompt for; names containing PASSWORD, SECRET or TOKEN are masked.")
                    .appFont(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Trust level").appFont(.caption).foregroundStyle(.secondary)
                Picker("Trust level", selection: $trustLevel) {
                    ForEach(CommandTrustLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                if trustLevel.rank < inferred.rank {
                    Label("The command reads as \(inferred.label.lowercased()); it will be confirmed at that level.", systemImage: "exclamationmark.triangle")
                        .appFont(.caption)
                        .foregroundStyle(Color.manageWarning)
                }
            }

            HStack {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                if case .edit = mode {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button(isAddMode ? "Add" : "Save") {
                    save()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: prefill)
        .confirmationDialog("Delete this command from the library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if case .edit(let categoryID, let command) = mode {
                    manage.deleteCommand(id: command.id, fromCategoryID: categoryID)
                }
                isPresented = false
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func prefill() {
        switch mode {
        case .add(let defaultCategoryID):
            selectedCategoryID = defaultCategoryID ?? manage.commandCategories.first?.id
        case .edit(_, let command):
            label = command.label
            commandText = command.command
            trustLevel = command.trustLevel
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never store a level weaker than the command reads as.
        let level = trustLevel.rank < inferred.rank ? inferred : trustLevel
        switch mode {
        case .add:
            let categoryID: UUID
            if isCreatingCategory {
                let name = newCategoryName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                categoryID = manage.addCategory(name: name)
            } else {
                guard let id = selectedCategoryID else { return }
                categoryID = id
            }
            manage.addCommand(toCategoryID: categoryID, label: trimmedLabel, command: trimmedCommand, trustLevel: level)
        case .edit(let categoryID, let command):
            manage.editCommand(id: command.id, inCategoryID: categoryID, label: trimmedLabel, command: trimmedCommand, trustLevel: level)
        }
    }
}

// MARK: - History

struct CommandHistoryPopover: View {
    @ObservedObject var manage: ManageState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").appFont(.headline)
                Spacer()
                if !manage.commandHistory.isEmpty {
                    Button("Clear") { manage.clearHistory() }
                        .buttonStyle(.borderless)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if manage.commandHistory.isEmpty {
                Text("No history yet")
                    .foregroundStyle(.secondary)
                    .appFont(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manage.commandHistory) { entry in
                            HistoryRow(manage: manage, entry: entry, isPresented: $isPresented)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 440)
    }
}

struct HistoryRow: View {
    @ObservedObject var manage: ManageState
    let entry: CommandHistoryEntry
    @Binding var isPresented: Bool
    @State private var isHovered = false

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label).appFont(.subheadline, weight: .medium).lineLimit(1)
                Text(entry.command)
                    .appFont(.footnote, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(relativeTime).appFont(.caption2).foregroundStyle(.secondary)
            Button("Use") {
                manage.customCommand = entry.command
                manage.selectedCommandID = nil
                isPresented = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Put this command in the box; Run confirms it as usual")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
    }
}
