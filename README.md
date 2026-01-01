# FleetMate for macOS

A Swift CLI tool for Mac fleet management that integrates with MunkiReport, Snipe-IT, and Munki repositories.

## Overview

FleetMate provides a unified command-line interface to query and manage your Mac fleet across multiple systems:

- **MunkiReport** - Query device status, managed installs, errors via SSH (no API needed)
- **Snipe-IT** - Asset management operations via REST API
- **Munki Repository** - Validate and lint pkgsinfo files

## Installation

### Requirements
- macOS 13.0 or later
- Swift 5.9 or later
- SSH access to MunkiReport server (for MunkiReport commands)

### Build from Source

```bash
git clone https://github.com/fleetmate-qa/fleetmate-macintosh.git
cd fleetmate-macintosh
swift build -c release
cp .build/release/fleetmate /usr/local/bin/
```

## Configuration

FleetMate looks for configuration in these locations (in order):
1. `~/.fleetmate.yaml`
2. `./.fleetmate.yaml`
3. Environment variables

### YAML Configuration

```yaml
# ~/.fleetmate.yaml
munkireport:
  url: https://munkireport.example.com
  ssh_host: munkireport.example.com
  ssh_user: ec2-user
  ssh_key_path: ~/.ssh/munkireport.pem
  db_path: /var/www/munkireport/app/db/db.sqlite

snipe:
  url: https://snipe.example.com
  api_key: your-api-key-here

deployment:
  path: /path/to/munki/deployment
```

### Environment Variables

```bash
export MUNKIREPORT_URL=https://munkireport.example.com
export MUNKIREPORT_SSH_HOST=munkireport.example.com
export MUNKIREPORT_SSH_USER=ec2-user
export MUNKIREPORT_SSH_KEY_PATH=~/.ssh/munkireport.pem
export MUNKIREPORT_DB_PATH=/var/www/munkireport/app/db/db.sqlite

export SNIPE_URL=https://snipe.example.com
export SNIPE_API_KEY=your-api-key

export FLEETMATE_DEPLOYMENT_PATH=/path/to/munki/deployment
```

## Commands

### Fleet Status

```bash
# Overview of all connected systems
fleetmate status

# Detailed status with verbose output
fleetmate status --verbose

# JSON output for automation
fleetmate status --json
```

### MunkiReport

```bash
# List all devices
fleetmate munkireport devices

# Filter by type
fleetmate munkireport devices --type Laptop

# Get specific device details
fleetmate munkireport device SERIAL123

# Get Munki run info
fleetmate munkireport info SERIAL123

# List managed installs for a device
fleetmate munkireport installs SERIAL123

# Find install errors
fleetmate munkireport errors
fleetmate munkireport errors --serial SERIAL123

# Find stale devices (haven't checked in)
fleetmate munkireport stale --days 7

# Run raw SQL query
fleetmate munkireport query "SELECT * FROM reportdata LIMIT 10"
```

### Snipe-IT

```bash
# List assets
fleetmate snipe assets
fleetmate snipe assets --status 2 --location 5

# Get specific asset
fleetmate snipe asset ECU12345
fleetmate snipe asset SERIAL123 --serial

# Search assets
fleetmate snipe search "MacBook Pro"

# List users and locations
fleetmate snipe users
fleetmate snipe locations

# Asset operations
fleetmate snipe checkout 123 --user 456
fleetmate snipe checkin 123
fleetmate snipe audit 123 --note "Verified on desk"
```

### Munki Repository

```bash
# Validate repository structure
fleetmate validate --path /path/to/deployment

# Show all warnings
fleetmate validate --verbose

# Lint pkgsinfo files
fleetmate lint --path /path/to/deployment

# Filter by rule
fleetmate lint --rule naming
```

## Architecture

```
Sources/FleetMate/
├── FleetMate.swift           # Main entry point
├── Commands/
│   ├── StatusCommand.swift   # Fleet overview
│   ├── MunkiReportCommand.swift
│   ├── SnipeCommand.swift
│   └── ValidateCommand.swift # Validate + Lint
├── Services/
│   ├── MunkiReportService.swift  # SSH-based queries
│   ├── SnipeService.swift        # REST API client
│   └── PkgInfoService.swift      # pkgsinfo parser
├── Models/
│   ├── MunkiModels.swift
│   └── SnipeModels.swift
└── Config/
    └── FleetMateConfig.swift
```

## MunkiReport SSH Integration

Since MunkiReport doesn't have a REST API, FleetMate connects via SSH and queries the SQLite database directly:

```bash
# Under the hood, this command:
fleetmate munkireport devices

# Executes:
ssh -i ~/.ssh/key.pem user@host "sqlite3 /path/to/db.sqlite 'SELECT * FROM reportdata'"
```

This approach provides:
- **Read access** to all MunkiReport data
- **No API dependencies** - works with any MunkiReport installation
- **Direct SQL** - run complex queries when needed

## Development

```bash
# Run in development
swift run fleetmate status

# Run tests
swift test

# Build release
swift build -c release
```

## Related Projects

- [FleetMate Windows](https://github.com/fleetmate-qa/fleetmate-windows) - C# CLI for Windows
- [Munki](https://github.com/munki/munki) - macOS package management
- [MunkiReport](https://github.com/munkireport/munkireport-php) - Reporting for Munki
- [Snipe-IT](https://github.com/snipe/snipe-it) - Asset management

## License

MIT License
