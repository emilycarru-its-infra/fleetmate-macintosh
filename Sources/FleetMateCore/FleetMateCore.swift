// FleetMateCore - Shared library for FleetMate CLI and GUI
//
// This module provides:
// - Configuration: FleetMateConfig
// - Keychain: KeychainService
// - Services: ReportMateService, SnipeService, GraphService, TdxService, DevOpsService, SecureShellService
// - Models: ReportMate, Snipe, Graph, TDX, DevOps, SSH models
// - Providers: Modular provider architecture for extensibility
//   - AssetProvider: Snipe-IT, ServiceNow, etc.
//   - ManagementProvider: Intune, Jamf, SimpleMDM, etc.
//   - TicketProvider: TDX, ServiceNow, Zendesk, etc.
//   - TaskProvider: Azure DevOps, GitHub, Gitea, Planner
//   - GroupProvider: Entra ID, Okta, etc.
//   - UserProvider: Snipe + Entra, Okta, etc.
//
// Usage:
//   import FleetMateCore
//
// All public types are available directly after importing this module.
//
// To add a new provider:
// 1. Create a new provider struct/class implementing the appropriate protocol
// 2. Register with the corresponding ProviderRegistry
// 3. The UI will automatically pick up the new provider

import Foundation

/// FleetMateCore library version
public let fleetMateCoreVersion = "1.1.0"
