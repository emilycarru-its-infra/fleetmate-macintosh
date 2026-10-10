import Foundation

// One builder per kind of thing FleetMate lists. Each names the item, its
// IDs, where it lives, and the `fleetmate` commands that fetch or act on it.
// Commands are left out where the CLI has none for that kind.

public extension AgentContext {
    // MARK: Projects

    /// A work item or issue from any task provider.
    static func workItem(_ task: UnifiedTask) -> AgentContext {
        let isDevOps = task.provider == "azdevops"
        let type = task.metadata["workItemType"]
        var fields = [Field(isDevOps ? "ID" : "Number", "#\(task.id)")]
        if let type { fields.append(Field("Type", type)) }
        fields.append(Field("State", task.metadata["state"] ?? task.state.rawValue))
        if !task.assignees.isEmpty { fields.append(Field("Assigned to", task.assignees.joined(separator: ", "))) }
        if let area = task.metadata["areaPath"] { fields.append(Field("Area", area)) }
        if let iteration = task.metadata["iterationPath"] ?? task.bucket { fields.append(Field("Iteration", iteration)) }
        if let priority = task.priority { fields.append(Field("Priority", String(priority))) }
        if !task.labels.isEmpty { fields.append(Field("Tags", task.labels.joined(separator: ", "))) }

        let commands: [Command]
        if isDevOps {
            commands = [
                Command("show the work item", FleetMateCommandLine.make("devops", "item", task.id)),
                Command("comment or change state", FleetMateCommandLine.make("devops", "update", task.id, "--comment", "<text>")),
            ]
        } else {
            commands = [Command("show the issue", FleetMateCommandLine.make("tasks", "show", task.provider, task.id))]
        }
        return AgentContext(kind: .workItem, title: task.title, source: providerName(task.provider),
                            project: task.metadata["teamProject"], url: task.externalUrl,
                            fields: fields, commands: commands)
    }

    /// An Azure DevOps shared query, with its WIQL when the API sent it.
    static func query(_ query: AdoSharedQuery, project: String?, url: String?, resultCount: Int? = nil) -> AgentContext {
        var fields = [Field("ID", query.id), Field("Query type", query.queryType)]
        if !query.folderPath.isEmpty { fields.append(Field("Folder", "Shared Queries/\(query.folderPath)")) }
        if let resultCount { fields.append(Field("Results shown", String(resultCount))) }
        return AgentContext(kind: .query, title: query.name, source: "Azure DevOps", project: project, url: url,
                            fields: fields, queryText: query.wiql, queryLanguage: "sql",
                            commands: [
                                Command("run the query", FleetMateCommandLine.make("devops", "queries", query.id)),
                                Command("results as JSON", FleetMateCommandLine.make("devops", "queries", query.id, "--json")),
                            ])
    }

    // MARK: Development

    static func pullRequest(_ pr: UnifiedPullRequest) -> AgentContext {
        var fields = [
            Field("Number", pr.reference),
            Field("Repository", "\(pr.container)/\(pr.repository)"),
            Field("Branches", "\(pr.sourceBranch) → \(pr.targetBranch)"),
            Field("State", pr.state.displayName + (pr.hasConflicts ? " (conflicts)" : "")),
            Field("Author", pr.authorName),
        ]
        if !pr.reviewers.isEmpty { fields.append(Field("Reviewers", pr.reviewers.map(\.displayName).joined(separator: ", "))) }
        let source = pr.source == .azureDevOps ? "azdo" : "github"
        return AgentContext(kind: .pullRequest, title: pr.title, source: pr.source.displayName,
                            project: pr.container, url: pr.webUrl, fields: fields,
                            commands: [
                                Command("your open pull requests", FleetMateCommandLine.make("prs", "--source", source)),
                                Command("the repository's recent commits", FleetMateCommandLine.make("repos", "log", "\(pr.container)/\(pr.repository)", "--ref", "origin/\(pr.sourceBranch)")),
                            ])
    }

    static func commit(_ commit: PullRequestCommit, in repository: RepositoryCommits) -> AgentContext {
        var fields = [Field("SHA", commit.id), Field("Repository", repository.displayName)]
        if let branch = repository.defaultBranch { fields.append(Field("Branch", branch)) }
        if let author = commit.authorName { fields.append(Field("Author", author)) }
        if let date = commit.date { fields.append(Field("Date", isoDate(date))) }
        return AgentContext(kind: .commit, title: commit.subject, source: repository.source.displayName,
                            project: repository.container, url: commit.url, fields: fields,
                            commands: [
                                Command("recent commits", FleetMateCommandLine.make("repos", "log", repository.displayName)),
                            ])
    }

    /// A pipeline run. The CLI has no pipeline command, so none is listed.
    static func pipelineRun(_ run: PipelineRun) -> AgentContext {
        var fields = [Field("Run ID", String(run.runId)), Field("Run", run.runNumber)]
        if let id = run.pipelineId { fields.append(Field("Pipeline ID", String(id))) }
        fields.append(Field("Status", run.status.displayName))
        if let repository = run.repository { fields.append(Field("Repository", "\(run.container)/\(repository)")) }
        if let branch = run.branch { fields.append(Field("Branch", branch)) }
        if let sha = run.commitSha { fields.append(Field("Commit", sha)) }
        if let by = run.triggeredBy { fields.append(Field("Triggered by", by)) }
        if let started = run.startedAt { fields.append(Field("Started", isoDate(started))) }
        return AgentContext(kind: .pipelineRun, title: run.pipelineName, source: run.source.displayName,
                            project: run.container, url: run.webUrl, fields: fields)
    }

    /// A repository FleetMate knows, with its local checkout when there is one.
    static func repository(_ record: RepoRecord) -> AgentContext {
        var fields = [Field("Repository", record.key.displayName)]
        if let path = record.local?.path { fields.append(Field("Checkout", path)) }
        if let branch = record.defaultBranch { fields.append(Field("Default branch", branch)) }
        var commands: [Command] = []
        if record.isLocal {
            commands.append(Command("branch and changes", FleetMateCommandLine.make("repos", "status", record.key.displayName, "--files")))
            commands.append(Command("recent commits", FleetMateCommandLine.make("repos", "log", record.key.displayName)))
        } else {
            commands.append(Command("clone it", FleetMateCommandLine.make("repos", "clone", record.key.displayName)))
        }
        return AgentContext(kind: .repository, title: record.key.name, source: repoProviderName(record.key.provider),
                            project: record.key.scope, url: record.catalog?.webUrl ?? record.local?.remoteUrl,
                            fields: fields, commands: commands)
    }

    /// A file inside a local checkout; `line` is 1-based.
    static func file(path: String, line: Int? = nil, in record: RepoRecord) -> AgentContext {
        var fields = [Field("Path", path)]
        if let line { fields.append(Field("Line", String(line))) }
        fields.append(Field("Repository", record.key.displayName))
        if let root = record.local?.path {
            fields.append(Field("Full path", (root as NSString).appendingPathComponent(path)))
        }
        return AgentContext(kind: .file, title: (path as NSString).lastPathComponent,
                            source: repoProviderName(record.key.provider), project: record.key.scope,
                            fields: fields,
                            commands: [
                                Command("uncommitted changes", FleetMateCommandLine.make("repos", "diff", record.key.displayName, path)),
                            ])
    }

    // MARK: Devices and Identity

    /// A device row joined from Intune, Apple's organization and Autopilot.
    static func device(_ row: DeviceListRow) -> AgentContext {
        let intune = row.intune
        var fields: [Field] = []
        if let serial = row.serialNumber { fields.append(Field("Serial", serial)) }
        if let intune { fields.append(Field("Intune ID", intune.id)) }
        if let entra = intune?.azureADDeviceId { fields.append(Field("Entra device ID", entra)) }
        if let platform = row.platformLabel {
            fields.append(Field("Platform", [platform, intune?.osVersion].compactMap { $0 }.joined(separator: " ")))
        }
        if let model = intune?.model ?? row.apple?.model { fields.append(Field("Model", model)) }
        if let user = intune?.userPrincipalName { fields.append(Field("User", user)) }
        if let compliance = intune?.complianceState { fields.append(Field("Compliance", compliance)) }
        if let sync = intune?.lastSyncDateTime { fields.append(Field("Last sync", sync)) }
        if !row.discrepancies.isEmpty { fields.append(Field("Discrepancies", row.discrepancies.joined(separator: ", "))) }

        var commands: [Command] = []
        if let serial = row.serialNumber {
            commands.append(Command("look it up in every system", FleetMateCommandLine.make("device", serial)))
        }
        if let intune {
            commands.append(Command("the Intune record", FleetMateCommandLine.make("intune", "device", intune.id)))
        }
        let title = intune?.deviceName ?? row.serialNumber ?? "Device"
        let source = intune != nil ? "Intune" : (row.apple != nil ? "Apple Business Manager" : "Autopilot")
        let url = intune.map { "https://intune.microsoft.com/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/~/overview/mdmDeviceId/\($0.id)" }
        return AgentContext(kind: .device, title: title, source: source, url: url, fields: fields, commands: commands)
    }

    static func user(_ user: EntraUser) -> AgentContext {
        var fields: [Field] = []
        if let upn = user.userPrincipalName { fields.append(Field("UPN", upn)) }
        if let id = user.id { fields.append(Field("Object ID", id)) }
        if let title = user.jobTitle { fields.append(Field("Job title", title)) }
        if let department = user.department { fields.append(Field("Department", department)) }
        if let enabled = user.accountEnabled { fields.append(Field("Account", enabled ? "Enabled" : "Disabled")) }
        let handle = user.userPrincipalName ?? user.id ?? ""
        let url = user.id.map { "https://entra.microsoft.com/#view/Microsoft_AAD_UsersAndTenants/UserProfileMenuBlade/~/overview/userId/\($0)" }
        return AgentContext(kind: .user, title: user.displayName ?? handle, source: "Entra ID", url: url, fields: fields,
                            commands: handle.isEmpty ? [] : [
                                Command("the user and their groups", FleetMateCommandLine.make("entra", "user", handle, "--groups")),
                            ])
    }

    static func group(_ group: EntraGroup) -> AgentContext {
        var fields: [Field] = []
        if let id = group.id { fields.append(Field("Object ID", id)) }
        if let mail = group.mail { fields.append(Field("Mail", mail)) }
        var kinds: [String] = []
        if group.groupTypes?.contains("Unified") == true { kinds.append("Microsoft 365") }
        if group.securityEnabled == true { kinds.append("Security") }
        if group.groupTypes?.contains("DynamicMembership") == true { kinds.append("Dynamic") }
        if !kinds.isEmpty { fields.append(Field("Type", kinds.joined(separator: ", "))) }
        if let description = group.description { fields.append(Field("Description", description)) }
        let handle = group.id ?? group.displayName ?? ""
        let url = group.id.map { "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/\($0)" }
        return AgentContext(kind: .group, title: group.displayName ?? handle, source: "Entra ID", url: url, fields: fields,
                            commands: handle.isEmpty ? [] : [
                                Command("the group and its members", FleetMateCommandLine.make("entra", "group", handle, "--members")),
                            ])
    }

    // MARK: Inventory, Tickets, Manage, Reporting

    /// `webBase` is the Snipe-IT address the asset page hangs off.
    static func asset(_ asset: SnipeAsset, webBase: String?) -> AgentContext {
        var fields = [Field("Asset ID", String(asset.id))]
        if let tag = asset.assetTag { fields.append(Field("Asset tag", tag)) }
        if let serial = asset.serial { fields.append(Field("Serial", serial)) }
        if let model = asset.model?.name { fields.append(Field("Model", model)) }
        if let status = asset.statusLabel?.name { fields.append(Field("Status", status)) }
        if let assigned = asset.assignedTo?.name { fields.append(Field("Assigned to", assigned)) }
        if let location = asset.location?.name { fields.append(Field("Location", location)) }
        var commands: [Command] = []
        if let handle = asset.assetTag ?? asset.serial {
            commands.append(Command("the asset record", FleetMateCommandLine.make("snipe", "asset", handle)))
        }
        if let serial = asset.serial {
            commands.append(Command("look it up in every system", FleetMateCommandLine.make("device", serial)))
        }
        let url = webBase.flatMap { base -> String? in
            let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return trimmed.isEmpty ? nil : "\(trimmed)/hardware/\(asset.id)"
        }
        return AgentContext(kind: .asset, title: asset.displayName ?? asset.assetTag ?? "Asset #\(asset.id)",
                            source: "Snipe-IT", url: url, fields: fields, commands: commands)
    }

    /// `url` comes from `FleetMateConfig.tdxTicketWebUrl`.
    static func ticket(_ ticket: TdxTicket, url: String?) -> AgentContext {
        let id = ticket.id.map(String.init) ?? ""
        var fields: [Field] = []
        if !id.isEmpty { fields.append(Field("ID", id)) }
        if let type = ticket.typeName { fields.append(Field("Type", type)) }
        if let status = ticket.statusName { fields.append(Field("Status", status)) }
        if let priority = ticket.priorityName { fields.append(Field("Priority", priority)) }
        if let requestor = ticket.requestorName { fields.append(Field("Requestor", requestor)) }
        if let responsible = ticket.responsibleFullName ?? ticket.responsibleGroupName {
            fields.append(Field("Responsible", responsible))
        }
        if let days = ticket.ageInDays { fields.append(Field("Age", "\(days)d")) }
        return AgentContext(kind: .ticket, title: ticket.title ?? "Ticket \(id)", source: "TeamDynamix",
                            project: ticket.accountName, url: url, fields: fields,
                            commands: id.isEmpty ? [] : [
                                Command("the ticket and its feed", FleetMateCommandLine.make("tdx", "ticket", id, "--feed")),
                                Command("add a comment", FleetMateCommandLine.make("tdx", "comment", id, "<text>")),
                            ])
    }

    /// A machine in the Manage roster, with its address when a scan found one.
    static func manageTarget(_ computer: RosterComputer, address: String? = nil) -> AgentContext {
        var fields: [Field] = []
        if computer.hasHostname { fields.append(Field("Hostname", computer.hostname)) }
        if !computer.isAdhoc { fields.append(Field("Serial", computer.serial)) }
        fields.append(Field("Asset tag", computer.asset))
        if let address { fields.append(Field("Address", address)) }
        fields.append(Field("Group", computer.fleet.isEmpty ? computer.location : computer.fleet))
        fields.append(Field("Platform", computer.platform))
        fields.append(Field("Status", computer.status))
        fields.append(Field("Allocation", computer.allocation))

        var commands: [Command] = []
        let host = computer.hasHostname ? computer.hostname : address
        if let host {
            commands.append(Command("check SSH", FleetMateCommandLine.make("ssh", "test", host)))
            commands.append(Command("run a command", FleetMateCommandLine.make("ssh", "exec", host, "<command>")))
        }
        if !computer.isAdhoc {
            commands.append(Command("look it up in every system", FleetMateCommandLine.make("device", computer.serial)))
        }
        return AgentContext(kind: .manageTarget, title: computer.displayName, source: "Manage roster",
                            fields: fields, commands: commands)
    }

    static func reportingDevice(_ device: ReportingDeviceRecord) -> AgentContext {
        var fields = [Field("Serial", device.serial)]
        if let hostname = device.hostname { fields.append(Field("Hostname", hostname)) }
        if let tag = device.assetTag { fields.append(Field("Asset tag", tag)) }
        if let platform = device.platform { fields.append(Field("Platform", platform)) }
        if let user = device.user { fields.append(Field("User", user)) }
        return AgentContext(kind: .reportingDevice, title: device.name, source: "ReportMate", fields: fields,
                            commands: [
                                Command("the ReportMate record", FleetMateCommandLine.make("reportmate", "device", device.serial)),
                                Command("look it up in every system", FleetMateCommandLine.make("device", device.serial)),
                            ])
    }

    // MARK: Helpers

    private static func providerName(_ provider: String) -> String {
        switch provider {
        case "azdevops": return "Azure DevOps"
        case "github": return "GitHub"
        case "gitea": return "Gitea"
        default: return provider
        }
    }

    private static func repoProviderName(_ provider: RepoProvider) -> String {
        switch provider {
        case .azureDevOps: return "Azure DevOps"
        case .gitHub: return "GitHub"
        case .other: return "Git"
        }
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
