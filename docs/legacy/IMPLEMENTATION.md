# FleetMate — Implementation Tracker

## Status: GUI Phase — Active Development

Last updated: 2026-01-30

---

## GUI Application Status

### macOS (SwiftUI)

| View | Status | Notes |
|------|--------|-------|
| ContentView (sidebar) | ✅ Complete | Dashboard, Devices, Inventory, Tickets, Tasks, Boards, Users, Groups |
| DashboardView | ✅ Complete | Fleet overview with quick stats |
| DevicesView | ✅ Complete | Table with sortable headers, always-visible actions panel, platform filter, compliance filter |
| AssetsView (Inventory) | ✅ Complete | Snipe-IT asset management |
| TicketsView | ✅ Complete | 60/40 split, feed filtering, comments, HTML decoding, me-mode default filter |
| WorkItemsView (Tasks) | ✅ Complete | Azure DevOps work items |
| BoardsView | ✅ Complete | Kanban board with Open/InProgress/Closed columns |
| UsersView | ✅ Complete | Entra ID user listing |
| GroupsView | ✅ Complete | Entra ID group management |
| TdxSsoLoginView | ✅ Complete | SAML interception, JWT retrieval, user info extraction |

### Windows (WPF + ModernWPF)

| View | Status | Notes |
|------|--------|-------|
| MainWindow (sidebar) | ✅ Complete | Dashboard, Devices, Inventory, Tickets, Tasks, Boards, Errors, Users, Groups |
| DashboardPage | ✅ Complete | Fleet overview |
| IntunePage (Devices) | ✅ Complete | Device management |
| AssetsPage (Inventory) | ✅ Complete | Snipe-IT assets |
| TicketsPage | ✅ Complete | Feed filter radio buttons |
| WorkItemsPage (Tasks) | ✅ Complete | Azure DevOps work items |
| BoardsPage | ✅ Complete | Kanban board |
| ErrorsPage | ✅ Complete | Installation errors |
| UsersPage | ✅ Complete | Entra ID users |
| GroupsPage | ✅ Complete | Entra ID groups |
| TdxSsoLoginWindow | ✅ Complete | WebView2 SSO, JWT retrieval, user info extraction |
| SettingsPage | ✅ Complete | Configuration UI |

### SSO Authentication

| Component | macOS | Windows |
|-----------|-------|---------|
| SAML/Shibboleth SSO | ✅ Working | ✅ Synced |
| SAML form interception | ✅ JS interceptor (WKWebView fix) | N/A (WebView2 handles natively) |
| JWT retrieval (/api/auth/loginSSO) | ✅ Working | ✅ Implemented |
| JWT payload parsing (user info) | ✅ Working | ✅ Implemented |
| Passkey / PSSO / Windows Hello | ⏳ Priority future work | ⏳ Priority future work |

See [SSO.md](SSO.md) for detailed SSO implementation documentation.

---

## Phase 1: Core Abstractions (Foundation) ✅

### 1.1 UnifiedTask Model
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Models/Tasks/UnifiedTask.cs` | ✅ Complete |
| Windows | `FleetMate.Core/Models/Tasks/TaskState.cs` | ✅ Complete |
| macOS | `FleetMateCore/Models/TaskModels.swift` | ✅ Complete |

### 1.2 ITaskProvider Interface / TaskProvider Protocol
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Services/Tasks/ITaskProvider.cs` | ✅ Complete |
| macOS | `FleetMateCore/Services/TaskProvider.swift` | ✅ Complete |

### 1.3 TaskProviderRegistry
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Services/Tasks/TaskProviderRegistry.cs` | ✅ Complete |
| macOS | `FleetMateCore/Services/TaskProviderRegistry.swift` | ✅ Complete |

### 1.4 Config Extension (tasks section)
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Config/FleetMateConfig.cs` | ✅ Complete |
| macOS | `FleetMateCore/Config/FleetMateConfig.swift` | ✅ Complete |

---

## Phase 2: Provider Implementations

### 2.1 AzureDevOpsTaskProvider (wrap existing service)
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Services/Tasks/AzureDevOpsTaskProvider.cs` | ⏳ Pending |
| macOS | `FleetMateCore/Services/AzureDevOpsTaskProvider.swift` | ⏳ Pending |

### 2.2 GitHubTaskProvider
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Services/Tasks/GitHubTaskProvider.cs` | ⏳ Pending |
| macOS | `FleetMateCore/Services/GitHubTaskProvider.swift` | ⏳ Pending |

### 2.3 GiteaTaskProvider
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Services/Tasks/GiteaTaskProvider.cs` | ⏳ Pending |
| macOS | `FleetMateCore/Services/GiteaTaskProvider.swift` | ⏳ Pending |

---

## Phase 3: Sync Services

### 3.1 PlannerSyncService (one-way push)
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Services/Sync/PlannerSyncService.cs` | ⏳ Pending |
| macOS | `FleetMateCore/Services/PlannerSyncService.swift` | ⏳ Pending |

### 3.2 MarkdownSyncService (bidirectional)
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.Core/Services/Sync/MarkdownSyncService.cs` | ⏳ Pending |
| macOS | `FleetMateCore/Services/MarkdownSyncService.swift` | ⏳ Pending |

---

## Phase 4: CLI Integration

### 4.1 TasksCommand
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.CLI/Commands/TasksCommand.cs` | ⏳ Pending |
| macOS | `FleetMate/Commands/TasksCommand.swift` | ⏳ Pending |

### 4.2 BoardsCommand
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.CLI/Commands/BoardsCommand.cs` | ⏳ Pending |
| macOS | `FleetMate/Commands/BoardsCommand.swift` | ⏳ Pending |

### 4.3 ErrorsCommand --task flag
| Platform | File | Status |
|----------|------|--------|
| Windows | `FleetMate.CLI/Commands/ErrorsCommand.cs` | ⏳ Pending |
| macOS | `FleetMate/Commands/ErrorsCommand.swift` | ⏳ Pending |

---

## Phase 5: GUI Integration

### 5.1 BoardsPage (Windows)
| File | Status |
|------|--------|
| `FleetMate.GUI/Views/BoardsPage.xaml` | ⏳ Pending |
| `FleetMate.GUI/Views/BoardsPage.xaml.cs` | ⏳ Pending |
| `FleetMate.GUI/ViewModels/BoardsViewModel.cs` | ⏳ Pending |
| `FleetMate.GUI/Views/MainWindow.xaml` (nav item) | ⏳ Pending |

### 5.2 BoardsView (macOS)
| File | Status |
|------|--------|
| `FleetMateApp/Views/BoardsView.swift` | ⏳ Pending |
| `FleetMateApp/ContentView.swift` (tab case) | ⏳ Pending |

---

## Dependencies to Add

| Platform | Package | Purpose |
|----------|---------|---------|
| Windows | Octokit (NuGet) | GitHub API |
| macOS | (none needed) | Alamofire already present |

---

## Notes

- AzureDevOpsTaskProvider **wraps** existing AzureDevOpsService (no breaking changes)
- New `tasks` config section **alongside** existing `azureDevOps` section
- Gitea uses direct REST API (no SDK)
- Planner sync is one-way push only
