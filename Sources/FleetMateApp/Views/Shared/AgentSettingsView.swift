import SwiftUI
import AgentsMate
import AppKit
import FleetMateCore

/// The person's own agent settings: how FleetMate opens, what a session runs,
/// whether one opens at launch, the agent CLIs, and usage and summaries. Each
/// falls back to the managed default until changed here. The repositories,
/// their order and the extra folders the new-session menu offers are in
/// Settings › Repositories.
struct AgentSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(AgentSettingsKey.command) private var command: String = ""
    @AppStorage(AgentSettingsKey.autoStart) private var autoStart: Bool = true
    @AppStorage(AgentSettingsKey.restoreSessions) private var restoreSessions: Bool = true
    @AppStorage(AgentSettingsKey.usageHost) private var usageHost: String = ""
    @State private var hasOwnCommand = false
    @State private var handbookRepo = ""
    @State private var handbookSite = ""
    @State private var skillsRepo = ""

    private var presetCommands: [String] { AgentLaunch.installedPresets.map(\.command) }

    var body: some View {
        Form {
            AgentsLaunchSettingsSection(store: appState.terminals.lanes)
            AgentSidebarSettingsSection(store: appState.terminals.lanes)

            Section {
                Picker("Runs", selection: presetBinding) {
                    ForEach(AgentLaunch.installedPresets, id: \.command) { preset in
                        Text(preset.label).tag(preset.command)
                    }
                    Text("Custom").tag("__custom__")
                }
                if !presetCommands.contains(command) {
                    TextField("Command", text: $command, prompt: Text("e.g. claude --model opus"))
                        .font(.system(.body, design: .monospaced))
                }
                Text("Codex follows your own permissions by default. Choose Codex (workspace) to allow work in the checkout and FleetMate's guide/context folders, with approvals on request.")
                    .appFont(.caption).foregroundStyle(.secondary)
                Toggle("Open a session when FleetMate starts", isOn: $autoStart)
                Toggle("Reopen the last sessions when FleetMate starts", isOn: $restoreSessions)
                    .help("Sessions open at quit come back in the list; Claude Code and Codex resume their last conversation when opened")
                AgentSummaryToggle(store: appState.terminals.lanes)
                TextField("Read usage from", text: $usageHost, prompt: Text("This Mac"))
                    .font(.system(.body, design: .monospaced))
                    .help("An ssh destination, such as user@other-mac, whose Claude status line writes the usage the sidebar meter shows. Leave it empty to read this Mac's. Applies at the next launch.")
                if let managed = appState.config.agentCommand, !hasOwnCommand {
                    Text("Your organization's default is \(managed.isEmpty ? "a shell" : "`\(managed)`").")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Sessions start in a login shell, so your PATH and tools are there. Each gets FLEETMATE_CONTEXT, a JSON file naming the tab and selection you're on, and FLEETMATE_AGENT_BRIEF, a guide to every fleetmate command; claude and codex sessions are given the guide at start. Toggle the panel with ⌘J or ⌃`. When your sessions run their agents on another Mac, set Read usage from to that Mac's ssh destination so the usage meter shows its figures; it reads them with ssh in batch mode, so a key must already let this Mac in.")
                    .settingsFooter()
            }

            AgentCliUpdatesSection(model: appState.terminals.updater)

            Section {
                TextField("Handbook repository", text: $handbookRepo, prompt: Text("Git clone URL"))
                TextField("Handbook site", text: $handbookSite, prompt: Text("Address of the published Handbook"))
                TextField("Skills repository", text: $skillsRepo, prompt: Text("Git clone URL of the shared skills"))
                HStack {
                    Spacer()
                    Button("Save", action: saveKnowledge).disabled(!knowledgeChanged)
                }
            } header: {
                Text("Handbook and Skills")
            } footer: {
                Text("The Handbook reader, its search results and cards, and the shared skills appear once these are set. A value from your organization's profile takes precedence.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            handbookRepo = appState.config.handbookRepoUrl ?? ""
            handbookSite = appState.config.handbookSiteUrl ?? ""
            skillsRepo = appState.config.agentsHubRepoUrl ?? ""
            hasOwnCommand = UserDefaults.standard.string(forKey: AgentSettingsKey.command) != nil
            if !hasOwnCommand { command = appState.config.agentCommand ?? AgentLaunch.defaultCommand }
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { presetCommands.contains(command) ? command : "__custom__" },
            set: { value in
                command = value == "__custom__" ? (presetCommands.contains(command) ? "claude " : command) : value
                hasOwnCommand = true
            }
        )
    }

    private func trimmed(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private var knowledgeChanged: Bool {
        trimmed(handbookRepo) != appState.config.handbookRepoUrl
            || trimmed(handbookSite) != appState.config.handbookSiteUrl
            || trimmed(skillsRepo) != appState.config.agentsHubRepoUrl
    }

    private func saveKnowledge() {
        var c = appState.config
        c.handbookRepoUrl = trimmed(handbookRepo)
        c.handbookSiteUrl = trimmed(handbookSite)
        c.agentsHubRepoUrl = trimmed(skillsRepo)
        appState.saveConfig(c)
    }
}

/// Settings › Shortcuts: every Agent command with its key, each one
/// changeable. A tab of its own, since the list is long.
struct ShortcutsSettingsView: View {
    @ObservedObject var store: AgentLaneStore

    var body: some View {
        Form {
            AgentLaneShortcutsSection(store: store)
        }
        .formStyle(.grouped)
    }
}

/// Settings › Agent's "Summarize sessions" switch, shown while the store has
/// a summary model. Observes the lane store itself, which the settings
/// window's app state does not republish.
private struct AgentSummaryToggle: View {
    @ObservedObject var store: AgentLaneStore

    var body: some View {
        if store.summariesAvailable {
            Toggle("Summarize sessions", isOn: Binding(get: { store.summariesEnabled },
                                                      set: { store.summariesEnabled = $0 }))
                .help("Each session's own agent writes a one-line summary for its row, a short call on your account when a new prompt arrives")
        }
    }
}

/// Settings › Agent › Agent CLIs: each CLI's version and install method, when
/// it was last checked, and the switch for keeping them current. Problems are
/// reported as a plain status line; the detail is in the app log.
private struct AgentCliUpdatesSection: View {
    @ObservedObject var model: AgentCliUpdateModel
    @AppStorage(AgentSettingsKey.keepClisCurrent) private var keepCurrent: Bool = true

    var body: some View {
        Section {
            Toggle("Keep agent CLIs up to date", isOn: $keepCurrent)
                .onChange(of: keepCurrent) { _, on in if on { model.updateIfStale() } }
            ForEach(AgentCli.allCases, id: \.self) { cli in
                row(cli, status: model.state.statuses.first { $0.cli == cli })
            }
            HStack {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                } else if let last = model.state.lastChecked {
                    Text("Last updated \(last.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update Now") { Task { await model.run(checkOnly: false) } }
                    .disabled(model.isRunning)
            }
            .appFont(.caption)
        } header: {
            Text("Agent CLIs")
        } footer: {
            Text("FleetMate updates codex and claude in the background with whatever installed them — Homebrew, npm or Claude's own installer — at launch and every six hours, so a session starts straight away instead of on an update. It never installs a missing CLI or asks for a password. While this is on, the CLIs skip their own update checks.")
                .appFont(.caption).foregroundStyle(.secondary)
        }
        .task {
            // Fill in versions the first time Settings is opened.
            if model.state.statuses.isEmpty, !model.isRunning { await model.run(checkOnly: true) }
        }
    }

    @ViewBuilder
    private func row(_ cli: AgentCli, status: AgentCliStatus?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(cli.displayName)
                Spacer()
                Text(status?.installed == false ? "Not installed" : (status?.version ?? "—"))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if cli == .codex, status?.installed == false {
                HStack {
                    Link("Codex setup instructions", destination: URL(string: "https://developers.openai.com/codex/quickstart")!)
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("npm install -g @openai/codex", forType: .string)
                    }
                    .buttonStyle(.borderless)
                }
                .appFont(.caption)
                Text("Run the command in Terminal if npm is installed, then start a new session. FleetMate does not install it automatically.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            if let status, status.installed {
                Text(detail(status))
                    .appFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func detail(_ status: AgentCliStatus) -> String {
        var parts: [String] = []
        if let method = status.method { parts.append(method.displayName) }
        if let checked = status.lastChecked {
            parts.append("checked \(checked.formatted(.relative(presentation: .named)))")
        }
        if let message = status.message { parts.append(message) }
        return parts.joined(separator: " · ")
    }
}
