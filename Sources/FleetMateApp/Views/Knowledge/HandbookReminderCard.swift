import SwiftUI
import FleetMateCore

/// Recently finished work that has no Handbook note yet. A gentle reminder,
/// never a gate: each item can be written up (an agent session opens with
/// the Handbook skill and the item in hand), marked "not needed" with a
/// reason, or simply left.
@MainActor
final class HandbookRemindersModel: ObservableObject {
    @Published private(set) var items: [WorkItem] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    private var loadedAt: Date?

    func load(appState: AppState, force: Bool = false) {
        guard let repo = appState.config.handbookRepoUrl, appState.config.isDevOpsConfigured else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 10 * 60 { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                items = try await appState.devOpsService.getFinishedWorkMissingHandbook(handbookRepoUrl: repo)
                loadedAt = Date()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func markNotNeeded(_ item: WorkItem, reason: String, appState: AppState) {
        Task {
            do {
                try await appState.devOpsService.markHandbookNotNeeded(item, reason: reason)
                items.removeAll { $0.id == item.id }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct HandbookReminderCard: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var model: HandbookRemindersModel
    @AppStorage("handbookReminders.expanded") private var expanded = false
    @State private var notNeededFor: Int?
    @State private var reason = ""

    var body: some View {
        if !model.items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "book.closed").foregroundStyle(.orange)
                        Text("\(model.items.count) recently finished item\(model.items.count == 1 ? "" : "s") without a Handbook note")
                            .appFont(.callout, weight: .medium)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help("Deliverables, features, stories and bugs finished in the last two weeks with no linked Handbook change (on the item or its tasks), no handbook-na tag and no \"Handbook:\" comment")

                if expanded {
                    Divider()
                    ForEach(model.items) { item in
                        row(item)
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func row(_ item: WorkItem) -> some View {
        HStack(spacing: 8) {
            Text("#\(item.id)").appFont(.caption, design: .monospaced).foregroundStyle(.secondary)
            Text(item.fields?.title ?? "Work item \(item.id)").appFont(.callout).lineLimit(1)
            Spacer()
            Button("Open") {
                appState.navigateToWorkItemId = item.id
                appState.navigateToTab = .projects
            }
            Button("Write it up") { draft(item) }
                .help("Open an agent session with the Handbook skill and this work item")
            Button("Not needed") { reason = ""; notNeededFor = item.id }
                .popover(isPresented: Binding(get: { notNeededFor == item.id }, set: { if !$0 { notNeededFor = nil } })) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Why no Handbook change?").appFont(.headline)
                        TextField("Nothing changed in how it is built or run", text: $reason)
                            .frame(width: 320)
                        HStack {
                            Spacer()
                            Button("Cancel") { notNeededFor = nil }
                            Button("Mark Not Needed") {
                                let why = reason.trimmingCharacters(in: .whitespaces)
                                model.markNotNeeded(item, reason: why.isEmpty ? "nothing changed in how it is built or run" : why,
                                                    appState: appState)
                                notNeededFor = nil
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// An agent session in the person's Handbook clone when they list one,
    /// asked to write up the item with the Handbook skill.
    private func draft(_ item: WorkItem) {
        let title = item.fields?.title ?? ""
        let prompt = "Use the handbook skill. Work item #\(item.id) (\(title)) is finished. Read it and its linked changes, decide whether the Handbook needs a new or updated page, and if so open a Handbook pull request and link it on the work item; if not, comment on the item starting with \"Handbook: not needed —\" and the reason."
        let agent = appState.agentDefaultLaunch.command.isEmpty ? "claude" : appState.agentDefaultLaunch.command
        let base = agent.split(separator: " ").first.map(String.init) ?? "claude"
        let command = (base == "claude" || base == "codex" ? base : "claude") + " " + AgentTerminalSession.quote(prompt)
        let handbookRepo = appState.agentRepos.first { $0.lowercased().hasSuffix("/handbook") }
        appState.terminals.open(AgentLaunch(command: command, directory: handbookRepo))
    }
}
