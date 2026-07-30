import SwiftUI
import FleetMateCore

/// Create a TDX ticket.
///
/// A deliberate subset of the TDX web form: every field here maps to something
/// `POST /api/{appId}/tickets` actually accepts. The web form's remaining
/// controls (Template, Contact(s), Asset/CI, Room, Attachment) are driven by
/// form-definition metadata the Web API does not expose, so they would be
/// decoration that silently drops what you typed.
struct CreateTicketView: View {
    @EnvironmentObject var appState: AppState

    /// Pre-selects Responsible, so the common case is one click.
    let defaultResponsible: TdxPerson?
    let onCreated: (TdxTicket) -> Void
    let onCancel: () -> Void

    // Content
    @State private var title = ""
    @State private var descriptionText = ""

    // Classification and routing
    @State private var classification: Int = TdxClassification.serviceRequest.rawValue
    @State private var typeId: Int = 0
    @State private var formId: Int = 0
    @State private var statusId: Int = 0
    @State private var priorityId: Int = 0
    @State private var sourceId: Int = 0
    @State private var accountId: Int = 0
    @State private var serviceId: Int = 0
    @State private var responsibleGroupId: Int = 0

    // People
    @State private var requestor: TdxPerson?
    @State private var responsible: TdxPerson?
    @State private var requestorQuery = ""
    @State private var responsibleQuery = ""
    @State private var requestorResults: [TdxPerson] = []
    @State private var responsibleResults: [TdxPerson] = []
    @State private var isSearchingRequestor = false
    @State private var isSearchingResponsible = false

    // Notification
    @State private var notifyRequestor = true
    @State private var notifyResponsible = true

    // Reference data
    @State private var types: [TdxLookupItem] = []
    @State private var forms: [TdxLookupItem] = []
    @State private var statuses: [TdxLookupItem] = []
    @State private var priorities: [TdxLookupItem] = []
    @State private var sources: [TdxLookupItem] = []
    @State private var accounts: [TdxLookupItem] = []
    @State private var services: [TdxLookupItem] = []
    @State private var groups: [TdxLookupItem] = []
    @State private var isLoadingReferenceData = true

    // Submission
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && typeId > 0
            && requestor != nil
            && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoadingReferenceData {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading ticket options…")
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    titleAndDescription
                    Divider()
                    peopleSection
                    Divider()
                    routingSection
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .task { await loadReferenceData() }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Create Ticket")
                    .appFont(.headline)
                Text(TdxClassification(rawValue: classification)?.name ?? "Ticket")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $classification) {
                ForEach(TdxClassification.allCases, id: \.rawValue) { option in
                    Text(option.name).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(action: save) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Create")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Sections

    private var titleAndDescription: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("Title", required: true) {
                TextField("Short summary of the request", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Details")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $descriptionText)
                    .appFont(.body)
                    .frame(height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            personField(
                label: "Requestor",
                required: true,
                selection: $requestor,
                query: $requestorQuery,
                results: $requestorResults,
                isSearching: $isSearchingRequestor
            )
            Toggle("Notify requestor", isOn: $notifyRequestor)
                .toggleStyle(.checkbox)
                .appFont(.caption)

            personField(
                label: "Responsible",
                required: false,
                selection: $responsible,
                query: $responsibleQuery,
                results: $responsibleResults,
                isSearching: $isSearchingResponsible
            )
            HStack(spacing: 12) {
                Toggle("Notify responsible", isOn: $notifyResponsible)
                    .toggleStyle(.checkbox)
                    .appFont(.caption)
                if let me = appState.tdxMe, responsible?.uid != me.uid {
                    Button("Assign to me") { responsible = me }
                        .buttonStyle(.link)
                        .appFont(.caption)
                }
            }

            labeled("Group") {
                lookupPicker(selection: $responsibleGroupId, items: groups, noneLabel: "No group")
            }
        }
    }

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Type", required: true) {
                lookupPicker(selection: $typeId, items: types, noneLabel: "Select a type")
            }
            labeled("Form") {
                lookupPicker(selection: $formId, items: forms, noneLabel: "Default form")
            }
            labeled("Service") {
                lookupPicker(selection: $serviceId, items: services, noneLabel: "No service")
            }
            labeled("Acct/Dept") {
                lookupPicker(selection: $accountId, items: accounts, noneLabel: "No account")
            }
            labeled("Source") {
                lookupPicker(selection: $sourceId, items: sources, noneLabel: "Default source")
            }
            labeled("Status") {
                lookupPicker(selection: $statusId, items: statuses, noneLabel: "Default status")
            }
            labeled("Priority") {
                lookupPicker(selection: $priorityId, items: priorities, noneLabel: "Default priority")
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func labeled<Content: View>(
        _ label: String,
        required: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 2) {
                Text(label)
                if required {
                    Text(verbatim: "*").foregroundColor(.red)
                }
            }
            .appFont(.caption)
            .foregroundColor(.secondary)
            .frame(width: 90, alignment: .leading)
            content()
        }
    }

    private func lookupPicker(selection: Binding<Int>, items: [TdxLookupItem], noneLabel: String) -> some View {
        Picker("", selection: selection) {
            Text(noneLabel).tag(0)
            ForEach(items) { item in
                Text(item.name).tag(item.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func personField(
        label: String,
        required: Bool,
        selection: Binding<TdxPerson?>,
        query: Binding<String>,
        results: Binding<[TdxPerson]>,
        isSearching: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            labeled(label, required: required) {
                if let person = selection.wrappedValue {
                    HStack(spacing: 6) {
                        Text(person.fullName ?? "—")
                            .appFont(.body)
                        if let email = person.primaryEmail, !email.isEmpty {
                            Text(email)
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button(action: {
                            selection.wrappedValue = nil
                            query.wrappedValue = ""
                            results.wrappedValue = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear \(label.lowercased())")
                        Spacer()
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                        TextField("Search people…", text: query)
                            .textFieldStyle(.plain)
                            .onChange(of: query.wrappedValue) { _, newValue in
                                search(newValue, into: results, isSearching: isSearching)
                            }
                        if isSearching.wrappedValue {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .padding(4)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(4)
                }
            }

            if selection.wrappedValue == nil && !results.wrappedValue.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results.wrappedValue, id: \.uid) { person in
                        Button(action: {
                            selection.wrappedValue = person
                            results.wrappedValue = []
                            query.wrappedValue = ""
                        }) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.fullName ?? "")
                                    .appFont(.caption)
                                    .foregroundColor(.primary)
                                if let email = person.primaryEmail, !email.isEmpty {
                                    Text(email)
                                        .appFont(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .padding(.leading, 98)
            }
        }
    }

    // MARK: - Data

    private func search(_ text: String, into results: Binding<[TdxPerson]>, isSearching: Binding<Bool>) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results.wrappedValue = []
            return
        }
        Task {
            isSearching.wrappedValue = true
            defer { isSearching.wrappedValue = false }
            results.wrappedValue = (try? await appState.tdxService.searchPeople(searchText: trimmed)) ?? []
        }
    }

    private func loadReferenceData() async {
        defer { isLoadingReferenceData = false }
        let service = appState.tdxService

        async let typesTask = try? await service.getTypeItems()
        async let formsTask = try? await service.getForms()
        async let statusTask = try? await service.getStatuses()
        async let priorityTask = try? await service.getPriorities()
        async let sourceTask = try? await service.getSources()
        async let accountTask = try? await service.getAccounts()
        async let serviceTask = try? await service.getServices()
        async let groupTask = try? await service.getGroups()

        types = await typesTask ?? []
        forms = (await formsTask ?? []).map { TdxLookupItem(id: $0.id, name: $0.name) }
        statuses = lookupItems(from: await statusTask ?? [:])
        priorities = lookupItems(from: await priorityTask ?? [:])
        sources = await sourceTask ?? []
        accounts = await accountTask ?? []
        services = await serviceTask ?? []
        groups = await groupTask ?? []

        applyDefaults()
    }

    private func lookupItems(from map: [Int: String]) -> [TdxLookupItem] {
        map.map { TdxLookupItem(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func applyDefaults() {
        let config = appState.config
        if typeId == 0, let defaultType = config.tdxDefaultTypeId { typeId = defaultType }
        if typeId == 0, types.count == 1 { typeId = types[0].id }
        if statusId == 0, let s = config.tdxDefaultStatusId { statusId = s }
        if priorityId == 0, let p = config.tdxDefaultPriorityId { priorityId = p }
        if sourceId == 0, let s = config.tdxDefaultSourceId { sourceId = s }
        if accountId == 0, let a = config.tdxDefaultAccountId { accountId = a }
        if responsibleGroupId == 0, let g = config.tdxResponsibleGroupId { responsibleGroupId = g }
        if requestor == nil { requestor = defaultResponsible }
        if responsible == nil { responsible = defaultResponsible }
    }

    // MARK: - Save

    private func save() {
        guard let requestorUid = requestor?.uid else {
            errorMessage = "Pick a requestor."
            return
        }
        Task {
            isSaving = true
            errorMessage = nil
            defer { isSaving = false }

            let trimmedDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = CreateTicketRequest(
                typeId: typeId,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: trimmedDescription.isEmpty ? nil : htmlParagraphs(trimmedDescription),
                classification: classification,
                formId: formId > 0 ? formId : nil,
                accountId: accountId > 0 ? accountId : nil,
                statusId: statusId > 0 ? statusId : nil,
                priorityId: priorityId > 0 ? priorityId : nil,
                sourceId: sourceId > 0 ? sourceId : nil,
                serviceId: serviceId > 0 ? serviceId : nil,
                requestorUid: requestorUid,
                responsibleUid: responsible?.uid,
                responsibleGroupId: responsibleGroupId > 0 ? responsibleGroupId : nil,
                isRichHtml: trimmedDescription.isEmpty ? nil : true
            )

            do {
                guard let created = try await appState.tdxService.createTicket(
                    request: request,
                    notifyRequestor: notifyRequestor,
                    notifyResponsible: notifyResponsible && responsible != nil
                ) else {
                    errorMessage = "Ticket not created — TeamDynamix rejected the session."
                    return
                }
                onCreated(created)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// TDX stores descriptions as HTML; plain newlines collapse without this.
    private func htmlParagraphs(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<p>\($0.isEmpty ? "&nbsp;" : String($0))</p>" }
            .joined()
    }
}
