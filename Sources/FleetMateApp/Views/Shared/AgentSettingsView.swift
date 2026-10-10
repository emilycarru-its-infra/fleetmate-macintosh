import SwiftUI
import AppKit
import FleetMateCore

/// The person's own terminal settings: what a session runs, whether one opens
/// at launch, and which repositories the new-session menu offers. Each falls
/// back to the managed default until changed here.
struct AgentSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(AgentSettingsKey.command) private var command: String = ""
    @AppStorage(AgentSettingsKey.autoStart) private var autoStart: Bool = true
    @State private var repos: [String] = []
    @State private var newRepo = ""
    @State private var hasOwnCommand = false
    @State private var handbookRepo = ""
    @State private var handbookSite = ""
    @State private var skillsRepo = ""

    private var presetCommands: [String] { AgentLaunch.installedPresets.map(\.command) }

    var body: some View {
        Form {
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
                Toggle("Open a session when FleetMate starts", isOn: $autoStart)
                if let managed = appState.config.agentCommand, !hasOwnCommand {
                    Text("Your organization's default is \(managed.isEmpty ? "a shell" : "`\(managed)`").")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Sessions start in a login shell, so your PATH and tools are there. Each gets FLEETMATE_CONTEXT, a JSON file naming the tab and selection you're on, and FLEETMATE_AGENT_BRIEF, a guide to every fleetmate command; claude and codex sessions are given the guide at start. Toggle the panel with ⌃`.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }

            AgentCliUpdatesSection(model: appState.terminals.updater)

            Section {
                if repos.isEmpty {
                    Text("No repositories yet.").foregroundStyle(.secondary)
                }
                ForEach(repos, id: \.self) { repo in
                    HStack {
                        Image(systemName: repo.contains("://") ? "link" : "folder")
                            .foregroundStyle(.secondary)
                        Text(repo).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            repos.removeAll { $0 == repo }
                            save()
                        } label: {
                            Label("Remove", systemImage: "minus.circle").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Path or clone URL", text: $newRepo)
                        .onSubmit(addTyped)
                    Button("Add", action: addTyped).disabled(newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Choose Folder…", action: chooseFolder)
                }
                Button("Reset to Organization Defaults") {
                    UserDefaults.standard.removeObject(forKey: AgentSettingsKey.repos)
                    repos = appState.config.repoDefaults
                }
                .disabled(UserDefaults.standard.stringArray(forKey: AgentSettingsKey.repos) == nil)
            } header: {
                Text("Repositories")
            } footer: {
                Text("Offered under New Session › Open in repository. Starts from your organization's list; your edits are yours alone.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }

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
                    .appFont(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            handbookRepo = appState.config.handbookRepoUrl ?? ""
            handbookSite = appState.config.handbookSiteUrl ?? ""
            skillsRepo = appState.config.agentsHubRepoUrl ?? ""
            repos = appState.agentRepos
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

    private func addTyped() {
        let value = newRepo.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !repos.contains(value) else { return }
        repos.append(value)
        newRepo = ""
        save()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in panel.urls {
            let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            if !repos.contains(path) { repos.append(path) }
        }
        save()
    }

    private func save() {
        UserDefaults.standard.set(repos, forKey: AgentSettingsKey.repos)
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
