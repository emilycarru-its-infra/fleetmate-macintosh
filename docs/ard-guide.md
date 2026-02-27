# FleetMate ARD — Developer Guide

## Overview

`fleetmate ard` is the Apple Remote Desktop / UNIX command runner built into the FleetMate CLI. It replaces ad-hoc shell scripts (like `scan-lab.sh`) with a consistent interface for running stock ARD scripts or custom commands on individual computers or entire groups, directly from the terminal or VS Code tasks.

---

## Prerequisites

```bash
# 1. Clone
git clone https://github.com/fleetmate-hq/fleetmate-macintosh
cd fleetmate-macintosh

# 2. Build
swift build --product fleetmate    # output at .build/debug/fleetmate

# 3. (Optional) symlink so it's on PATH
ln -sf "$PWD/.build/debug/fleetmate" /usr/local/bin/fleetmate

# 4. Config (~/.fleetmate/config.yaml)
reportmate:
  url: https://reportmate.example.com
  passphrase: your-passphrase
secureShell:
  privateKeyPath: ~/.ssh/id_ed25519
```

---

## Targeting: one device or a whole group

Every script command accepts either `--device` or `--group`:

| Flag | Accepts |
|---|---|
| `--device / -d` | device name, serial number, hostname, or IP address |
| `--group / -g` | ReportMate location name **or** path to a `.csv` file |

```bash
# Single device
fleetmate ard updates check --device Mac-Studio-01

# Named group (resolved via ReportMate)
fleetmate ard updates check --group "B1122 Studio Lab"

# CSV group (column 1 = name or IP, lines starting with # are comments)
fleetmate ard updates check --group ~/Desktop/lab.csv
```

---

## All subcommands

### Group operations (no SSH required)

```bash
fleetmate ard group scan  <group>     # Ping table: IP + online/offline status per computer
fleetmate ard group list              # List all ReportMate location groups
fleetmate ard group preview <csv>     # Preview which computers a CSV file would target
```

### Custom command runner

```bash
fleetmate ard run "<shell-cmd>" --device <name>    # Run any shell command on one device
fleetmate ard run "<shell-cmd>" --group  <group>   # Run on all devices in a group
```

### Screen Sharing

```bash
fleetmate ard vnc <device>    # Opens Screen Sharing (vnc://) to the specified device
```

### Inventory

```bash
fleetmate ard inventory ip           --device|--group ...
fleetmate ard inventory info         --device|--group ...
fleetmate ard inventory serial       --device|--group ...
fleetmate ard inventory hardware     --device|--group ...
fleetmate ard inventory serial-list  --device|--group ...
```

### Security

```bash
fleetmate ard security filevault        --device|--group ...
fleetmate ard security sip              --device|--group ...
fleetmate ard security gatekeeper       --device|--group ...
fleetmate ard security defender         --device|--group ...
fleetmate ard security password-policy  --device|--group ...
```

### Updates

```bash
fleetmate ard updates check           --device|--group ...
fleetmate ard updates install         --device|--group ...
fleetmate ard updates softwareupdate  --device|--group ...
```

### Munki

```bash
fleetmate ard munki config        --device|--group ...
fleetmate ard munki run           --device|--group ...
fleetmate ard munki manifest      --device|--group ...
fleetmate ard munki force-check   --device|--group ...
```

### Upkeep

```bash
fleetmate ard upkeep storage       --device|--group ...
fleetmate ard upkeep running-apps  --device|--group ...
fleetmate ard upkeep reboot        --device|--group ... --confirm   # destructive
fleetmate ard upkeep shutdown      --device|--group ... --confirm   # destructive
```

### Users

```bash
fleetmate ard users list          --device|--group ...
fleetmate ard users admin-check   --device|--group ...
fleetmate ard users login-items   --device|--group ...
```

### Profiles

```bash
fleetmate ard profiles list    --device|--group ...
fleetmate ard profiles remove  --device|--group ...
```

### Dock

```bash
fleetmate ard dock list   --device|--group ...
fleetmate ard dock reset  --device|--group ...
```

### Printing

```bash
fleetmate ard printing list      --device|--group ...
fleetmate ard printing defaults  --device|--group ...
```

### Enrollment

```bash
fleetmate ard enrollment dep        --device|--group ...
fleetmate ard enrollment mdm-status --device|--group ...
fleetmate ard enrollment re-enroll  --device|--group ...
```

### Logs

```bash
fleetmate ard logs crash    --device|--group ...
fleetmate ard logs system   --device|--group ...
fleetmate ard logs install  --device|--group ...
```

### macOS

```bash
fleetmate ard macos version       --device|--group ...
fleetmate ard macos erase-install --device|--group ... --confirm   # destructive
```

> **Note:** Commands marked `--confirm` require that flag to be passed explicitly. They will not run without it.

---

## JSON output

All commands support `--json` / `-j` for machine-readable output:

```bash
fleetmate ard group scan "B1122 Studio Lab" --json | jq '.[] | select(.online)'
fleetmate ard inventory ip --group computers.csv --json > report.json
```

---

## Run everything from VS Code

The repo ships `.vscode/tasks.json`. Open any FleetMate file, then:

```
Cmd+Shift+P -> Tasks: Run Task
```

Available tasks include:

| Task label | What it does |
|---|---|
| Build: fleetmate CLI (debug) | `swift build --product fleetmate` |
| ARD: Scan Group (IP + status table) | Prompts for group name, opens new terminal |
| ARD: List All Groups | Lists all ReportMate location groups |
| ARD: Preview CSV Group | Prompts for CSV path, shows what would be targeted |
| ARD: Run Custom Command (device) | Prompts for command + device |
| ARD: Run Custom Command (group) | Prompts for command + group |
| ARD: Open VNC / Screen Sharing | Prompts for device, launches Screen Sharing |
| ARD: Get IP Addresses (group) | inventory ip on a group |
| ARD: About This Mac (device) | inventory info on one device |
| ARD: Check for Updates (group) | updates check on a group |
| ARD: Install Updates (group) | updates install on a group |
| ARD: Check FileVault (group) | security filevault on a group |
| ARD: Run Defender Scan (group) | security defender on a group |
| ARD: Storage Check (group) | upkeep storage on a group |
| ARD: List Running Apps (device) | upkeep running-apps on one device |
| ARD: Reboot (device — with confirm) | upkeep reboot --confirm on one device |
| ARD: Show Munki Config (device) | munki config on one device |
| ARD: Check DEP Enrollment (device) | enrollment dep on one device |

Each task that takes a group name or device name will prompt you via a VS Code input box before running.

---

## Adding a new ARD script

1. Find or write the shell script (same category prefix convention as `ard_sample/`).
2. Add a subcommand struct to the relevant category in [Sources/FleetMate/Commands/Devices/ArdCommand.swift](../Sources/FleetMate/Commands/Devices/ArdCommand.swift):

```swift
struct ArdSecurityMyNewCheckSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "my-new-check",
        abstract: "Short description of what it checks"
    )
    @OptionGroup var targeting: ArdTargetOptions

    func run() async throws {
        try await ArdRunner.run(
            script: "sudo /usr/local/bin/my_script.sh",
            targeting: targeting
        )
    }
}
```

3. Register it in the parent command's `subcommands:` array.
4. `swift build --product fleetmate`
5. Optionally add a matching entry in `.vscode/tasks.json`.

---

## File layout

```
fleetmate-macintosh/
  Sources/FleetMate/Commands/Devices/
    ArdCommand.swift          <- all ARD logic lives here
  .vscode/
    tasks.json                <- VS Code Run Task wiring
  docs/
    ard-guide.md              <- this file
```

---

## Feature map (vs. standalone scan-lab.sh)

| Feature | scan-lab.sh | FleetMate ARD |
|---|---|---|
| Ping table (IP + status) | Yes | `ard group scan` |
| VS Code Run Task | Yes | Built-in via tasks.json |
| CSV group targeting | Yes | `--group path/to/file.csv` |
| Bulk SSH custom command | No | `ard run "<cmd>" --group ...` |
| VNC / Screen Sharing | No | `ard vnc <device>` |
| All ard_sample/ scripts | No | `ard inventory\|security\|updates\|...` |
| ReportMate group lookup | No | `--group "Location Name"` |
| JSON output for scripting | No | `--json` on every command |
