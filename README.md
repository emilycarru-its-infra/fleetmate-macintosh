# FleetMate

> Enterprise IT fleet orchestration, asset management, and deployment monitoring CLI for macOS

FleetMate is a unified command-line interface for managing IT assets across multiple systems including Snipe-IT, TeamDynamix, Microsoft Intune/Entra, ReportMate, and Azure DevOps. Built for macOS with Swift 5.9+, it provides a consistent interface for fleet management tasks with deep integration into macOS security features like Keychain.

## Features

- **Fleet Monitoring** - Real-time device status and error tracking via ReportMate
- **Asset Management** - Complete Snipe-IT integration (assets, users, locations, checkout/checkin)
- **Ticketing** - TeamDynamix ticket and asset management
- **Identity & Device** - Microsoft Entra ID and Intune integration
- **Remote Execution** - SecureShell (SSH) based remote command execution
- **Rich Output** - Beautiful tables with color formatting and JSON export support
- **Secure Credentials** - All secrets stored in macOS Keychain
- **Flexible Config** - Environment variables, Keychain, or YAML configuration

## Quick Start

### Installation

Build from source:

```bash
git clone https://github.com/fleetmate-qa/fleetmate-macintosh.git
cd fleetmate-macintosh
swift build -c release
```

The compiled binary will be at `.build/release/fleetmate`.

### Configuration

FleetMate uses a priority-based configuration system:

1. **Environment Variables** (highest priority)
2. **macOS Keychain** (secure credential storage)
3. **config.yaml** (in current directory or `~/.fleetmate/`)

**Quick Setup:**
```bash
# Run interactive configuration wizard
fleetmate configure

# Or set environment variables
export SNIPE_URL="https://snipe.example.com"
export SNIPE_API_KEY="your-api-key"
export REPORTMATE_URL="https://reportmate.example.com"
export REPORTMATE_PASSPHRASE="your-passphrase"
```

**Keychain Storage:**
```bash
# Store credentials securely in Keychain
fleetmate configure set reportmate-url "https://reportmate.example.com"
fleetmate configure set reportmate-passphrase "your-passphrase"
fleetmate configure set snipe-url "https://snipe.example.com"
fleetmate configure set snipe-api-key "your-api-key"

# View configured services
fleetmate configure list

# Verify configuration
fleetmate configure status
```

### Verify Installation

```bash
fleetmate status
```

This displays your configuration, available services, and connection status.

## Command Reference

### Fleet Monitoring

Monitor deployment health and troubleshoot installation failures:

```bash
# Look up device by serial, hostname, or asset tag
fleetmate device A000123

# List all installation errors
fleetmate errors

# List errors for specific package
fleetmate errors --item "Adobe Creative Cloud"

# Deep-dive troubleshooting for specific package
fleetmate troubleshoot "Adobe Creative Cloud"
```

### Asset Management (Snipe-IT)

Comprehensive Snipe-IT integration:

```bash
# Search assets
fleetmate snipe assets --search "laptop"
fleetmate snipe assets --status 2 --location 5

# Get asset details (by tag, serial, or ID)
fleetmate snipe asset A000123

# Asset lifecycle
fleetmate snipe checkout 923 --user 42 --note "Assigned to new hire"
fleetmate snipe checkin 923 --note "Returned from user"
fleetmate snipe audit 923 --location 5

# Users and locations
fleetmate snipe users --search "bryan"
fleetmate snipe user 42
fleetmate snipe locations

# Asset metadata
fleetmate snipe models
fleetmate snipe categories
fleetmate snipe manufacturers
fleetmate snipe statuses

# Licenses and inventory
fleetmate snipe licenses --search "Adobe"
fleetmate snipe accessories
fleetmate snipe consumables
fleetmate snipe components

# Activity log
fleetmate snipe activity --limit 50
```

### TeamDynamix

Asset and ticket management:

```bash
# Search assets
fleetmate tdx assets --search A000123 --limit 10

# Get asset details with all fields
fleetmate tdx asset 243576 --json

# Ticket management
fleetmate tdx tickets --status "New" --priority "High"
fleetmate tdx ticket 12345
fleetmate tdx create "Laptop not booting" --description "User reports black screen"
fleetmate tdx comment 12345 "Troubleshooting steps taken..."
```

### Remote Execution (SecureShell)

SSH-based remote command execution:

```bash
# Execute single command
fleetmate ssh exec A000123 "hostname"
fleetmate ssh exec REMOTE-24 "sudo managedsoftwareupdate --checkonly"

# Batch execution
fleetmate ssh batch A000123 REMOTE-24 STUDIO-10 --command "uptime"

# Test connectivity
fleetmate ssh test A000123

# Retrieve Munki logs
fleetmate ssh logs A000123 --lines 50

# Run Munki commands
fleetmate ssh munki check A000123
fleetmate ssh munki prefs A000123
```

### Microsoft Graph (Intune/Entra)

Query Intune devices and Entra users:

```bash
# Intune devices
fleetmate intune devices
fleetmate intune device EXAMPLE4  # by serial
fleetmate intune compliance <device-id>

# Entra users
fleetmate entra user first.last@example.edu
fleetmate entra groups
fleetmate entra check-group first.last@example.edu "IT Staff"
```

### Azure DevOps

Work item management:

```bash
# List work items
fleetmate devops items --state Active
fleetmate devops items --assigned-to "me"

# Work item details
fleetmate devops item 1234

# Create work items
fleetmate devops create "Fix deployment error" --type Task
fleetmate devops from-error "Adobe Creative Cloud"  # auto-create from error

# Update work items
fleetmate devops update 1234 --state Resolved --comment "Fixed by script update"
```

### MunkiReport

Query MunkiReport database (legacy support):

```bash
# List devices
fleetmate munkireport devices

# Device details
fleetmate munkireport device A000123

# Munki info
fleetmate munkireport info A000123

# Managed installs
fleetmate munkireport installs A000123

# Installation errors
fleetmate munkireport errors

# Stale devices
fleetmate munkireport stale --days 14

# Raw SQL query
fleetmate munkireport query "SELECT serial_number, hostname FROM machines WHERE os_version LIKE '14.%'"
```

### Quality Assurance

Package validation and testing:

```bash
# Validate package structure
fleetmate validate /path/to/package

# Lint pkginfo files
fleetmate lint /path/to/pkginfo
```

## JSON Output

All commands support `--json` for programmatic consumption:

```bash
fleetmate snipe asset A000123 --json | jq .
fleetmate tdx assets --search A000123 --json | jq .
fleetmate intune device EXAMPLE4 --json | jq .
```

## Configuration Reference

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `REPORTMATE_URL` | ReportMate API endpoint | `https://reportmate.example.edu` |
| `REPORTMATE_PASSPHRASE` | ReportMate authentication token | `your-token` |
| `SNIPE_URL` | Snipe-IT base URL | `https://snipe.example.edu` |
| `SNIPE_API_KEY` | Snipe-IT API key | `your-api-key` |
| `TDX_BASE_URL` | TeamDynamix API endpoint | `https://servicedesk.emilycarru.ca/TDWebApi` |
| `TDX_APP_ID` | TeamDynamix application ID | `116` |
| `TDX_BEID` | TeamDynamix BEID | `your-beid` |
| `TDX_WEB_SERVICES_KEY` | TeamDynamix web services key | `your-key` |
| `SECURE_SHELL_PRIVATE_KEY_PATH` | Path to SSH private key | `~/.ssh/id_rsa` |
| `SECURE_SHELL_DEFAULT_USERNAME` | Default SSH username | `administrator` |

### Keychain Keys

All credentials can be stored securely in macOS Keychain:

- `reportMateUrl`, `reportMatePassphrase`
- `snipeUrl`, `snipeApiKey`
- `graphTenantId`, `graphClientId`, `graphClientSecret`
- `devopsOrganization`, `devopsProject`, `devopsPat`
- `tdxBaseUrl`, `tdxAppId`, `tdxBeid`, `tdxWebServicesKey`
- `tdxUsername`, `tdxPassword`
- `sshPrivateKey`, `sshKeyPath`, `sshDefaultUsername`, `sshKeyVaultName`

### Config File (config.yaml)

```yaml
reportmate:
  url: https://reportmate.example.edu
  passphrase: your-passphrase

snipe:
  url: https://snipe.example.edu
  api_key: your-api-key

tdx:
  base_url: https://servicedesk.emilycarru.ca/TDWebApi
  app_id: 116
  beid: your-beid
  web_services_key: your-key

secure_shell:
  default_username: administrator
  key_path: ~/.ssh/id_rsa

logging:
  path: /var/log/fleetmate
  level: info
```

## Architecture

```
fleetmate-macintosh/
├── Package.swift                # Swift Package Manager manifest
├── Sources/
│   ├── FleetMate/              # CLI executable
│   │   ├── FleetMate.swift     # Entry point
│   │   └── Commands/           # Command implementations
│   │       ├── StatusCommand.swift
│   │       ├── DeviceCommand.swift
│   │       ├── SnipeCommand.swift
│   │       ├── TdxCommand.swift
│   │       ├── IntuneCommand.swift
│   │       ├── EntraCommand.swift
│   │       ├── SecureShellCommand.swift
│   │       └── ...
│   ├── FleetMateCore/          # Core business logic
│   │   ├── FleetMateCore.swift
│   │   ├── Services/           # API clients
│   │   │   ├── ReportMateService.swift
│   │   │   ├── SnipeService.swift
│   │   │   ├── TdxService.swift
│   │   │   ├── GraphService.swift
│   │   │   ├── SecureShellService.swift
│   │   │   └── KeychainService.swift
│   │   ├── Models/             # Data models
│   │   │   ├── Snipe/
│   │   │   ├── Tdx/
│   │   │   ├── Graph/
│   │   │   ├── ReportMate/
│   │   │   └── SecureShell/
│   │   └── Config/
│   │       └── FleetMateConfig.swift
│   └── FleetMateApp/           # SwiftUI GUI (future)
│       ├── FleetMateApp.swift
│       ├── ContentView.swift
│       └── Views/
└── Tests/
    └── FleetMateTests/
```

### Tech Stack

- **Swift 5.9+** - Modern, safe, and performant
- **swift-argument-parser 1.3+** - Robust CLI framework
- **Alamofire 5.8+** - Elegant HTTP networking
- **SwiftNIO 2.65+ / SwiftNIO SSH 0.8+** - Async I/O and SSH
- **Swift Crypto 3.0+** - Cryptographic operations
- **Yams 5.0+** - YAML configuration parsing
- **Rainbow 4.0+** - Terminal text coloring
- **Security framework** - macOS Keychain integration

## Troubleshooting

### Keychain Access

First run may require keychain access permission:

```bash
# Grant keychain access when prompted
fleetmate configure set snipe-api-key "your-key"

# Verify keychain storage
fleetmate configure list
```

### TDX Authentication Errors

If you see error 487 "unregistered host name":

```bash
# Check configuration
fleetmate configure list

# Update if incorrect
fleetmate configure set tdx-base-url "https://servicedesk.emilycarru.ca/TDWebApi"
fleetmate configure set tdx-app-id "116"
```

### SecureShell Connection Failures

```bash
# Test connectivity
fleetmate ssh test A000123

# Verify key permissions and format
# Key should be PEM format, no passphrase
# Set via keychain or environment variable
export SECURE_SHELL_PRIVATE_KEY_PATH=~/.ssh/id_rsa
```

### Missing Configuration

```bash
# Run status to see what's configured
fleetmate status --verbose

# Use interactive wizard
fleetmate configure

# Or manually set environment variables
export SNIPE_URL="https://snipe.example.com"
export SNIPE_API_KEY="your-key"
```

## Development

### Prerequisites

- macOS 14.0+
- Xcode 15.0+ or Swift 5.9+ toolchain
- Command Line Tools

### Build & Test

```bash
# Clone repository
git clone https://github.com/fleetmate-qa/fleetmate-macintosh.git
cd fleetmate-macintosh

# Build debug version
swift build

# Run directly
swift run fleetmate status

# Build release version
swift build -c release

# Run tests
swift test
```

### Release Build

```bash
# Build optimized release binary
swift build -c release

# Binary location
.build/release/fleetmate

# Install to /usr/local/bin
sudo cp .build/release/fleetmate /usr/local/bin/
```

## Comparison with Windows Version

FleetMate for macOS maintains feature parity with the Windows C# version:

| Feature | macOS (Swift) | Windows (C#) |
|---------|---------------|--------------|
| ReportMate Integration | ✅ | ✅ |
| Snipe-IT Full API | ✅ | ✅ |
| TeamDynamix | ✅ | ✅ |
| Microsoft Graph/Intune | ✅ | ✅ |
| Azure DevOps | ✅ | ✅ |
| SecureShell (SSH) | ✅ | ✅ |
| Credential Storage | Keychain | Registry |
| Config Format | YAML/Env | YAML/Env/.env |
| GUI | SwiftUI (planned) | WPF (available) |
| Platform | macOS 14+ | Windows 10+ |

## License

Proprietary - Emily Carr University of Art + Design

## Support

For issues or questions:
- File an issue on GitHub
- Contact IT Systems team
- Review logs in `/var/log/fleetmate/`
