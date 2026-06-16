## Plan: FleetMate — Unified Fleet Management Hub

FleetMate is a cross-platform (macOS + Windows) fleet management application with CLI and GUI interfaces. It integrates with Intune, Entra ID, Snipe-IT, TeamDynamix, Azure DevOps, and more.

### Current Priorities

1. **PSSO / Passkey / Windows Hello SSO** — Platform SSO and FIDO2 credential support for TDX SSO (see [SSO.md](SSO.md))
2. **Provider-agnostic task/board management** — Unified task management across Azure DevOps, GitHub, Gitea (see Boards plan below)
3. **UI polish** — Table sorting, filters, and responsive layouts

---

## Plan: FleetMate Boards — Unified Task Management

Extend FleetMate (Windows + macOS) into a unified fleet management hub with provider-agnostic task/board management. Each provider (Azure DevOps, GitHub, Gitea) is independently toggleable — users configure which systems they use. Tasks sync one-way to Microsoft Planner for visibility, and local `.md` files enable agent/AI workflows.

**Architecture**

FleetMate becomes the single app for:
- Device management (existing)
- Error tracking → task creation (`fleetmate errors --task`)
- Boards/tasks UI (new views in FleetMate.GUI / FleetMateApp)
- Multi-provider task aggregation
- `.md` file sync for agents

**Steps**

1. **Define unified task abstraction in FleetMate.Core**
   - Create `Models/Tasks/UnifiedTask.cs` with common fields: `Id`, `Provider`, `Title`, `Description`, `State` (Open/InProgress/Closed), `Assignees[]`, `Labels[]`, `Bucket`, `DueDate`, `CreatedAt`, `UpdatedAt`, `ClosedAt`, `ExternalUrl`, `ProviderData`
   - Create `ITaskProvider` interface: `AuthenticateAsync()`, `ListTasksAsync()`, `GetTaskAsync()`, `CreateTaskAsync()`, `UpdateTaskAsync()`, `DeleteTaskAsync()`, `ListBucketsAsync()`, `ListLabelsAsync()`
   - Mirror in Swift: `TaskProvider` protocol + `UnifiedTask` struct in FleetMateCore

2. **Refactor existing Azure DevOps service**
   - Windows: Extract `ITaskProvider` from [AzureDevOpsService.cs](FleetMate.Core/Services/AzureDevOpsService.cs) → `AzureDevOpsTaskProvider`
   - macOS: Extract `TaskProvider` protocol from [AzureDevOpsService.swift](Sources/FleetMateCore/Services/AzureDevOpsService.swift) → `AzureDevOpsTaskProvider`
   - Keep existing CRUD, wrap in new interface

3. **Implement GitHub provider**
   - Windows: `GitHubTaskProvider.cs` — REST API for Issues + GraphQL for Projects v2
   - macOS: `GitHubTaskProvider.swift`
   - Auth: Fine-grained PAT or `gh` CLI token
   - Map: `state` (open/closed) → `TaskState`, labels → labels, milestone → bucket

4. **Implement Gitea provider**
   - Windows: `GiteaTaskProvider.cs` — REST API v1.25
   - macOS: `GiteaTaskProvider.swift`
   - Auth: API token via `Authorization: token {token}` header
   - Note: No Projects API — use milestones as buckets
   - CLI fallback: `tea` commands for advanced operations

5. **Create provider registry with toggles**
   - Config supports enabling/disabling each provider independently:
     ```yaml
     tasks:
       providers:
         azdevops:
           enabled: true
           organization: "example-org"
           project: "Devices"
         github:
           enabled: true
           owner: "fleetmate-qa"
           repo: "fleetmate-windows"
         gitea:
           enabled: false
           url: "https://git.example.com"
           owner: "team"
           repo: "planning"
       planner:
         enabled: true
         plan_id: "abc123"
       markdown:
         enabled: true
         repo_path: "~/planning"
     ```
   - `TaskProviderRegistry` aggregates tasks from all enabled providers
   - Each provider has its own credentials section

6. **Implement Planner sync service** (one-way push)
   - Create `PlannerSyncService` (write-only, not a TaskProvider)
   - Map: `TaskState.Open` → 0%, `InProgress` → 50%, `Closed` → 100%
   - Handle ETag versioning for updates
   - Sync on task create/update from any enabled provider
   - Store mapping: `(provider, externalId) → plannerId`
   - Labels → `appliedCategories` (first 6 labels)

7. **Implement `.md` file sync**
   - Create `MarkdownSyncService` for bidirectional sync:
     - `boards/{board-name}.md` — Kanban-style markdown
     - `tasks/{provider}-{id}.md` — Individual task details
   - Format: YAML frontmatter + markdown body
   - Watch file changes → push to provider; provider changes → update files
   - Git-based conflict resolution
   - Example:
     ```
     ~/planning/
       boards/
         devices-sprint-1.md
         infrastructure.md
       tasks/
         azdevops-12345.md
         github-42.md
       .sync-state.json
     ```

8. **Add Boards UI to FleetMate GUI**
   - Windows: New `BoardsPage.xaml` in FleetMate.GUI with:
     - Provider filter/toggle
     - Kanban board view (columns by state)
     - Task list view
     - Task detail panel
     - Create/edit task forms
   - macOS: New `BoardsView.swift` in FleetMateApp/Views with same features
   - Aggregate view: Show tasks from all enabled providers in unified board

9. **Update CLI commands**
   - `fleetmate errors --task` — Create task from error in default provider
   - `fleetmate tasks list [--provider azdevops|github|gitea|all]`
   - `fleetmate tasks create --title "..." --provider github`
   - `fleetmate tasks sync` — Force sync .md files
   - `fleetmate boards` — List boards/buckets across providers

10. **CLI tool integration**
    - Shell out to `az boards`, `gh issue`, `tea issue` for operations not in REST API
    - Use as fallback when API calls fail
    - Detect installed CLIs at startup

**Verification**

- Unit tests: Mock `ITaskProvider`/`TaskProvider` implementations
- Integration tests: Create/read/update task round-trip per provider
- Sync tests: Modify `.md` file → verify provider updated; provider → `.md`
- Planner sync: Create task in any provider → verify appears in Planner
- CLI: `fleetmate errors --task` creates task in configured default provider
- GUI: Unified board shows tasks from multiple enabled providers

**Decisions**

- **Build on FleetMate** over separate TaskMate project (leverage existing code + single hub)
- **Independent provider toggles** over priority ordering (each can be on/off)
- **Central `planning` repo** for .md files (simpler agent access)
- **One-way Planner sync** over bidirectional (avoids ETag conflicts)
- **`--task` flag** over `--create-work-item` (shorter, clearer)
