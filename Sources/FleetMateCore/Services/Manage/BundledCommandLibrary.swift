import Foundation

/// The macOS command library that ships inside FleetMate: the ScanLab
/// library, verbatim. Seeded to the per-user file on first use and merged
/// into it afterwards, so operators keep their edits and still receive new
/// bundled commands. Edit the YAML between the raw-string markers; a test
/// keeps it parsing and audit-clean.
public enum BundledCommandLibrary {
    public static let yaml = #"""
categories:
  - name: System
    commands:
      - label: Hostname
        command: hostname
        trust: safe
      - label: Uptime
        command: uptime
        trust: safe
      - label: macOS version (short)
        command: sw_vers --productVersion
        trust: safe
      - label: macOS version (full)
        command: sw_vers
        trust: safe
      - label: Hardware info (model, chip, serial, RAM, disk)
        command: 'H=$(system_profiler SPHardwareDataType 2>/dev/null); printf ''%s\n'' "$H" | grep ''Model Name\|Chip\|Serial''; printf ''RAM: %.1f GB\n'' "$(sysctl -n hw.memsize 2>/dev/null | awk ''{print $1/1073741824}'')"; D=$(diskutil info / 2>/dev/null | awk -F'': *'' ''/Disk Size/{print $2; exit}''); [ -n "$D" ] && echo "Disk: $D" || echo ''Disk: unavailable'''
        trust: safe
      - label: Identity summary (serial, UUID, hostname, Microsoft ID)
        command: 'SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F'': *'' ''/Serial Number \(system\)/{print $2; exit}''); UUID=$(ioreg -d2 -c IOPlatformExpertDevice | awk -F\" ''/IOPlatformUUID/{print $(NF-1); exit}''); HOST=$(scutil --get HostName 2>/dev/null || hostname); MSID=$(defaults read /Library/Preferences/com.microsoft.CompanyPortalMac UserPrincipalName 2>/dev/null || defaults read com.microsoft.CompanyPortalMac UserPrincipalName 2>/dev/null || dscl . -read /Users/$(stat -f ''%Su'' /dev/console) EMailAddress 2>/dev/null | awk ''NR==2{print $1; exit}''); [ -z "$MSID" ] && MSID=''not found''; echo "Serial: ${SERIAL:-unknown}"; echo "UUID: ${UUID:-unknown}"; echo "Hostname: ${HOST:-unknown}"; echo "Microsoft ID: $MSID"'
        trust: safe
      - label: Computer name
        command: sudo scutil --get ComputerName
        trust: safe
      - label: RAM (GB)
        command: 'sysctl hw.memsize | awk ''{printf "%.1f GB\n", $2/1073741824}'''
        trust: safe
      - label: Serial number
        command: 'system_profiler SPHardwareDataType 2>/dev/null | awk ''/Serial/ {print $4}'''
        trust: safe
      - label: All installed apps + versions
        command: 'system_profiler SPApplicationsDataType | tr -s '' '' | sed -e ''s/^ //g'' | awk ''/:$/ {print $0}; /Version:/ {print $2}'''
        trust: safe
      - label: Architecture (Apple Silicon / Intel)
        command: uname -m
        trust: safe
      - label: Rosetta installed
        command: '/usr/bin/pgrep -q oahd && echo ''Rosetta installed'' || echo ''Rosetta not installed'''
        trust: safe
      - label: Date and time
        command: date
        trust: safe
      - label: Timezone
        command: sudo systemsetup -gettimezone
        trust: safe
      - label: CPU top processes
        command: 'top -l 1 -stats pid,command,cpu -n 10 | tail -11'
        trust: safe
      - label: Memory pressure
        command: memory_pressure
        trust: safe
  - name: Storage
    commands:
      - label: Disk usage (/)
        command: 'df -h / | tail -1'
        trust: safe
      - label: Users disk usage
        command: 'sudo du -xhd 1 /Users 2>/dev/null | sort -hr | head -25'
        trust: safe
      - label: Available storage
        command: 'system_profiler SPStorageDataType 2>/dev/null | grep -E "Free:|Capacity:|Mount Point:" | head -6'
        trust: safe
      - label: BTM database listing
        command: 'sudo ls -lh /private/var/db/com.apple.backgroundtaskmanagement/ 2>/dev/null || echo "BTM directory access restricted (SIP protected on macOS 13+)"; sudo ls -la /private/var/db/ 2>/dev/null | grep backgroundtask'
        trust: safe
      - label: BTM database sizes
        command: 'sudo du -sh /private/var/db/com.apple.backgroundtaskmanagement/ 2>/dev/null || echo "BTM directory access restricted (SIP protected on macOS 13+)"'
        trust: safe
      - label: BTM wipe database
        command: 'sudo rm -f /private/var/db/com.apple.backgroundtaskmanagement/* && echo ''BTM wiped'''
        trust: safe
  - name: Munki Config
    commands:
      - label: Munki ClientIdentifier
        command: 'defaults read /Library/Preferences/ManagedInstalls ClientIdentifier 2>/dev/null || echo ''not set'''
        trust: safe
      - label: Munki full config (repo + client + auth)
        command: 'echo ''Repo:''; defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL 2>/dev/null; echo ''Client:''; defaults read /Library/Preferences/ManagedInstalls ClientIdentifier 2>/dev/null; echo ''Auth:''; sudo defaults read ManagedInstalls AdditionalHttpHeaders 2>/dev/null || echo ''none'''
        trust: safe
      - label: Munki launchctl status
        command: 'sudo launchctl list | grep -i munki'
        trust: safe
      - label: Munki run preflight
        command: sudo /usr/local/munki/preflight
        trust: safe
      - label: Munki ManagedInstallReport
        command: cat /Library/Managed\ Installs/ManagedInstallReport.plist
        trust: safe
      - label: Munki SelfServeManifest
        command: 'cat /Library/Managed\ Installs/manifests/SelfServeManifest 2>/dev/null || echo ''no SelfServeManifest'''
        trust: safe
  - name: Munki Operations
    commands:
      - label: Last Munki run (from log)
        command: 'if [ ! -f "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log" ]; then echo "No Munki log found"; else awk ''/Beginning managed software check/{delete run; n=0; found=1} found{run[++n]=$0} END{if(!found){print "No managed software check found in log"; exit} for(i=1;i<=n;i++) print run[i]}'' "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log"; fi'
        trust: safe
      - label: Last Munki run result summary
        command: 'if [ ! -f "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log" ]; then echo "No Munki log found"; else awk ''/Beginning managed software check/{delete run; n=0; found=1} found{run[++n]=$0} END{for(i=1;i<=n;i++) print run[i]}'' "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log" | grep -E "The following|Nothing to do|Installed|Error|WARNING|managed software check" || echo "No matching result lines in last Munki run"; fi'
        trust: safe
      - label: Run Munki check + show log
        command: 'sudo /usr/local/munki/managedsoftwareupdate --checkonly 2>/dev/null; echo "--- check complete ---"; awk ''/Beginning managed software check/{found=NR} found{lines[NR]=$0} END{for(i=found;i<=NR;i++) print lines[i]}'' "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log" 2>/dev/null'
        trust: safe
      - label: Munki check only (verbose)
        command: sudo /usr/local/munki/managedsoftwareupdate -vv --checkonly
        trust: safe
      - label: Munki install only (verbose)
        command: sudo /usr/local/munki/managedsoftwareupdate -vv --installonly
        trust: safe
      - label: Run Munki install + show log
        command: 'sudo /usr/local/munki/managedsoftwareupdate --installonly 2>/dev/null; echo "--- install complete ---"; tail -100 "/Library/Managed Installs/Logs/Install.log" 2>/dev/null || echo "No install log found"'
        trust: caution
      - label: Run Munki check + install + show log
        command: 'sudo /usr/local/munki/managedsoftwareupdate --checkonly 2>/dev/null && sudo /usr/local/munki/managedsoftwareupdate --installonly 2>/dev/null; echo "--- complete ---"; tail -100 "/Library/Managed Installs/Logs/Install.log" 2>/dev/null'
        trust: caution
      - label: Munki list cache
        command: 'FILES=$(ls "/Library/Managed Installs/Cache" 2>/dev/null); [ -n "$FILES" ] && echo "$FILES" || echo "Cache is empty (nothing pending)"'
        trust: safe
      - label: Munki clear cache
        command: 'sudo rm -rf "/Library/Managed Installs/Cache" && echo ''Munki cache cleared'''
        trust: destructive
      - label: Munki set bootstrap flag
        command: 'touch /Users/Shared/.com.googlecode.munki.checkandinstallatstartup && echo ''Bootstrap set'''
        trust: safe
      - label: Munki remove bootstrap flag
        command: 'rm -f /Users/Shared/.com.googlecode.munki.checkandinstallatstartup && echo ''Bootstrap removed'''
        trust: safe
      - label: 'Munki today''s install log'
        command: 'RESULT=$(cat "/Library/Managed Installs/Logs/Install.log" 2>/dev/null | grep "$(date +\''%Y-%m-%d\'')"); [ -n "$RESULT" ] && echo "$RESULT" || echo "No installs today"'
        trust: safe
      - label: 'Munki today''s update log'
        command: 'RESULT=$(cat "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log" 2>/dev/null | grep "$(date +\''%Y-%m-%d\'')"); [ -n "$RESULT" ] && echo "$RESULT" || echo "No Munki activity logged today"'
        trust: safe
  - name: macOS Updates
    commands:
      - label: List available macOS updates
        command: sudo softwareupdate -l
        trust: safe
      - label: Update history (last 20)
        command: 'softwareupdate --history | head -20'
        trust: safe
      - label: Install outstanding macOS updates + restart
        command: 'UPDATES=$(softwareupdate -l 2>&1 | awk -F''Label: '' ''/^[[:space:]]*\* Label: /{print $2}'' | grep -Ei ''^(macOS|Security Update|Rapid Security Response)''); if [ -n "$UPDATES" ]; then printf "%s\n" "$UPDATES" | while IFS= read -r update; do echo "Installing OS update and restarting if required: $update"; printf "%s\n" <PASSWORD> | sudo softwareupdate --install "$update" --user <USERNAME> --stdinpass --verbose --restart 2>&1 | awk ''$0 != last { print; last = $0 }''; done; else echo "No macOS OS updates found"; fi'
        trust: caution
  - name: MDM & Enrollment
    commands:
      - label: BootstrapToken status
        command: sudo profiles status -type bootstraptoken
        trust: safe
      - label: Token & MDM summary
        command: 'BTGEN=$(sudo profiles status -type bootstraptoken 2>/dev/null | awk -F": " "/Bootstrap Token supported on server/{print \$NF}"); BTESC=$(sudo profiles status -type bootstraptoken 2>/dev/null | awk -F": " "/escrowed to server/{print \$NF}"); URL=$(sudo profiles status -type enrollment 2>/dev/null | sed -n "s/^[[:space:]]*MDM server:[[:space:]]*//p" | head -1); if [ -z "$URL" ]; then MDM=none; elif echo "$URL" | grep -qiE "micromdm|mdm\.ecuad"; then MDM=MicroMDM; elif echo "$URL" | grep -qiE "manage\.microsoft|intune"; then MDM=Intune; else MDM=unknown; fi; TOKENS=$(dscl . list /Users UniqueID 2>/dev/null | awk "\$2 >= 500 && \$1 !~ /^_/ {print \$1}" | while read u; do if sudo sysadminctl -secureTokenStatus "$u" 2>&1 | grep -q ENABLED; then printf "%s=Y " "$u"; else printf "%s=N " "$u"; fi; done); printf "MDM=%s | BootstrapToken supported=%s escrowed=%s | Tokens: %s" "$MDM" "${BTGEN:-?}" "${BTESC:-?}" "${TOKENS:-none }"'
        trust: safe
      - label: DEP enrollment check
        command: 'OUT=$(sudo profiles status -type enrollment 2>/dev/null || true); if echo "$OUT" | grep -qiE ''Enrolled via (DEP|ADE):[[:space:]]*Yes|is Enrolled via DEP:[[:space:]]*Yes|MDM enrollment:[[:space:]]*Yes''; then echo ''DEP enrolled''; elif sudo profiles show -type enrollment 2>/dev/null | grep -q ''ConfigurationURL''; then echo ''DEP enrolled''; else echo ''NOT DEP enrolled''; fi'
        trust: safe
      - label: DEP enrollment profile
        command: sudo profiles show -type enrollment
        trust: safe
      - label: APNS topic
        command: 'TOPICS=$(sudo system_profiler SPConfigurationProfileDataType 2>/dev/null | grep -o ''com\.apple\.mgmt\.[^"]*'' | sort -u | head -3 || true); [ -n "$TOPICS" ] && printf ''%s\n'' "$TOPICS" || echo ''No APNS topic found'''
        trust: safe
      - label: Device UUID
        command: 'ioreg -d2 -c IOPlatformExpertDevice | awk -F\\\" ''/IOPlatformUUID/{print $(NF-1)}'''
        trust: safe
      - label: Re-enroll existing machine
        command: sudo profiles renew -type enrollment
        trust: caution
      - label: Check Secure Tokens
        command: sudo fdesetup list -extended
        trust: safe
  - name: Security & Profiles
    commands:
      - label: FileVault status
        command: sudo fdesetup status
        trust: safe
      - label: SIP status
        command: csrutil status
        trust: safe
      - label: MDM enrollment health
        command: 'COUNT=$(log show --predicate ''subsystem == "com.apple.ManagedClient"'' --last 1h --style compact 2>&1 | grep -c ''Server: (null)'' || true); if [ "${COUNT:-0}" -gt 0 ]; then echo "BROKEN - Server: (null) seen $COUNT times"; else echo "OK"; fi'
        trust: safe
      - label: MicroMDM SCEP cert check
        command: 'sudo security find-certificate -a -c ''MicroMDM'' /Library/Keychains/System.keychain 2>&1 | grep ''labl'' | sed ''s/.*=\"//;s/\"//'' || echo ''MISSING - no MicroMDM cert'''
        trust: safe
      - label: MDM re-enroll (fix broken)
        command: sudo profiles -N
        trust: destructive
      - label: Installed profiles (identifiers)
        command: 'sudo profiles list 2>/dev/null | grep profileIdentifier'
        trust: safe
      - label: Installed profiles count
        command: 'sudo profiles list 2>/dev/null | grep -c profileIdentifier'
        trust: safe
      - label: Detailed profiles info
        command: sudo system_profiler SPConfigurationProfileDataType
        trust: safe
      - label: SSH remote login status
        command: sudo systemsetup -getremotelogin
        trust: safe
      - label: Screen Sharing service status
        command: sudo launchctl print system/com.apple.screensharing
        trust: safe
      - label: Remote access readiness
        command: 'echo "Hostname: $(hostname)"; echo "IP addresses:"; ifconfig | awk ''/inet / && $2 != "127.0.0.1" {print "  " $2}''; echo "Console user: $(stat -f ''%Su'' /dev/console 2>/dev/null || echo unknown)"; echo "Remote Login: $(sudo systemsetup -getremotelogin 2>/dev/null | awk -F'': '' ''{print $2}'')"; if sudo lsof -nP -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1; then echo "SSH port 22: listening"; else echo "SSH port 22: not listening"; fi; if sudo launchctl print system/com.apple.screensharing >/tmp/scanlab-screensharing.$$ 2>/dev/null; then if grep -q ''state = running'' /tmp/scanlab-screensharing.$$; then echo "Screen Sharing service: running"; else echo "Screen Sharing service: loaded, not running"; fi; else echo "Screen Sharing service: not loaded"; fi; rm -f /tmp/scanlab-screensharing.$$; if sudo lsof -nP -iTCP:5900 -sTCP:LISTEN >/dev/null 2>&1; then echo "Screen Sharing port 5900: listening"; else echo "Screen Sharing port 5900: not listening"; fi'
        trust: safe
      - label: Enable SSH remote login
        command: 'sudo systemsetup -setremotelogin on && echo ''SSH enabled'''
        trust: caution
      - label: Gatekeeper status
        command: spctl --status
        trust: safe
      - label: Reset TCC Camera + Microphone
        command: 'sudo tccutil reset Camera && sudo tccutil reset Microphone && echo ''TCC reset'''
        trust: caution
      - label: Check AutoLogin settings
        command: 'system_profiler SPConfigurationProfileDataType | grep autoLoginUser'
        trust: safe
      - label: Root SSH user on?
        command: 'dscl . -read /Users/root UserShell 2>/dev/null | grep -v ''/usr/bin/false'' | grep -q ''bash\|zsh\|sh'' && echo ''Root login ENABLED'' || echo ''Root login disabled'''
        trust: safe
      - label: Run Defender quick scan
        command: sudo /usr/local/bin/mdatp scan quick
        trust: safe
      - label: Run Defender full scan
        command: sudo /usr/local/bin/mdatp scan full
        trust: safe
      - label: Defender status
        command: /usr/local/bin/mdatp health
        trust: safe
  - name: Users & Sessions
    commands:
      - label: Recent logins (last 10)
        command: last -10
        trust: safe
      - label: Who is logged in
        command: who
        trust: safe
      - label: Current console user
        command: 'stat -f ''%Su'' /dev/console'
        trust: safe
      - label: Log out current user
        command: 'sudo launchctl bootout gui/$(id -u $(stat -f ''%Su'' /dev/console)) && echo ''User logged out'''
        trust: caution
      - label: Lock screen
        command: 'CONSOLE_USER=$(stat -f ''%Su'' /dev/console 2>/dev/null || true); if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then echo ''No logged-in user session to lock''; elif UID=$(id -u "$CONSOLE_USER" 2>/dev/null); then sudo launchctl asuser "$UID" osascript -e ''tell application "System Events" to keystroke "q" using {control down, command down}'' 2>/dev/null && echo "Lock requested for $CONSOLE_USER" || { pmset displaysleepnow; echo ''Lock keystroke unavailable; display sleep requested''; }; else echo "Could not resolve user ID for $CONSOLE_USER"; fi'
        trust: caution
      - label: Unlock screen (manual)
        command: 'echo ''Unlock requires the user password at the login window (local or Screen Sharing). Remote unlock is not supported for security.'''
        trust: safe
      - label: Login window events (last hour)
        command: 'sudo log show --predicate ''process == "loginwindow"'' --last 1h --style compact | tail -20'
        trust: safe
      - label: List users
        command: ls /Users
        trust: safe
      - label: Admin group members
        command: dscl . -read /Groups/admin GroupMembership
        trust: safe
      - label: Local users and UIDs
        command: 'dscl . list /Users UniqueID | awk ''$2 >= 500 && $1 !~ /^_/ {print $1 "\t" $2}'''
        trust: safe
      - label: Create admin account (template)
        command: 'echo ''Run manually with your values:''; echo ''sudo sysadminctl -addUser <USERNAME> -password <PASSWORD> -admin'''
        trust: destructive
      - label: Secure token status (all local users)
        command: 'sudo dscl . list /Users UniqueID | awk ''$2 >= 500 && $1 !~ /^_/ {print $1}'' | while read u; do printf ''%s\\t'' \"$u\"; sysadminctl -secureTokenStatus \"$u\" 2>&1 | awk -F'': '' ''/Secure token is/{print $2}''; done'
        trust: safe
      - label: Secure token status (admins only)
        command: 'for u in $(dscl . -read /Groups/admin GroupMembership 2>/dev/null | cut -d: -f2-); do [ \"$u\" = \"root\" ] && continue; printf ''%s\\t'' \"$u\"; sysadminctl -secureTokenStatus \"$u\" 2>&1 | awk -F'': '' ''/Secure token is/{print $2}''; done'
        trust: safe
      - label: Bootstrap token status
        command: sudo profiles status -type bootstraptoken
        trust: safe
      - label: FileVault status & enabled users
        command: 'fdesetup status; echo ''--- FileVault users ---''; sudo fdesetup list 2>/dev/null'
        trust: safe
  - name: Network
    commands:
      - label: DNS servers
        command: 'for SVC in "Wi-Fi" "Ethernet"; do echo "== $SVC (manual override) =="; OUT=$(networksetup -getdnsservers "$SVC" 2>/dev/null || true); if echo "$OUT" | grep -qi "There aren''t any DNS Servers set"; then echo "none (using DHCP/system resolver)"; elif [ -n "$OUT" ]; then echo "$OUT"; else echo "service unavailable"; fi; echo; done; echo "== Effective DNS resolvers (active) =="; DNS=$(scutil --dns 2>/dev/null | awk ''/nameserver\[[0-9]+\]/{print $3}'' | sort -u); [ -n "$DNS" ] && echo "$DNS" || echo "none detected"'
        trust: safe
      - label: IP address (en0)
        command: 'ifconfig en0 | grep ''inet '' | awk ''{print $2}'''
        trust: safe
      - label: All IP addresses
        command: 'echo ''Ethernet:''; ipconfig getifaddr en0 2>/dev/null || echo ''none''; echo ''WiFi:''; ipconfig getifaddr en1 2>/dev/null || echo ''none'''
        trust: safe
      - label: WiFi network name
        command: 'WIFI_DEV=$(networksetup -listallhardwareports 2>/dev/null | awk ''/Hardware Port: Wi-Fi/{getline; print $2; exit}''); if [ -n "$WIFI_DEV" ]; then OUT=$(networksetup -getairportnetwork "$WIFI_DEV" 2>/dev/null || true); if echo "$OUT" | grep -qi ''Current Wi-Fi Network''; then echo "$OUT"; elif [ -x /usr/bin/wdutil ]; then SSID=$(/usr/bin/wdutil info 2>/dev/null | awk -F'': '' ''/^[[:space:]]*SSID/{print $2; exit}''); [ -n "$SSID" ] && echo "Current Wi-Fi Network: $SSID" || echo ''Wi-Fi SSID unavailable (interface off or not associated)''; else echo ''Wi-Fi SSID unavailable (interface off or not associated)''; fi; else echo ''Wi-Fi interface not found''; fi'
        trust: safe
      - label: WiFi signal strength
        command: 'if [ -x /usr/bin/wdutil ]; then WIFI_INFO=$(/usr/bin/wdutil info 2>/dev/null | awk ''/SSID|RSSI|Noise|Tx Rate|Channel/{print}''); [ -n "$WIFI_INFO" ] && echo "$WIFI_INFO" || echo ''Wi-Fi signal unavailable (interface off or not associated)''; else echo ''wdutil unavailable; Wi-Fi signal unsupported on this macOS version''; fi'
        trust: safe
      - label: Open network connections
        command: 'netstat -an | grep ESTABLISHED | head -20'
        trust: safe
  - name: Printing
    commands:
      - label: List printers
        command: 'lpstat -p 2>/dev/null | cut -d'' '' -f2 || echo ''none'''
        trust: safe
      - label: Detailed printer info
        command: sudo system_profiler SPPrintersDataType
        trust: safe
      - label: List print jobs
        command: lpq -a
        trust: safe
      - label: Default printer
        command: lpstat -d
        trust: safe
      - label: Reset print system
        command: 'sudo lpstat -p 2>/dev/null | cut -d'' '' -f2 | xargs -I{} lpadmin -x {} && echo ''Print system reset'''
        trust: destructive
      - label: Cancel all print jobs
        command: cancel -a -
        trust: caution
      - label: Remove ECU printers
        command: 'lpstat -p | cut -d'' '' -f2 | grep ECU_ | xargs -n1 sudo lpadmin -x && echo ''ECU printers removed'''
        trust: destructive
  - name: Diagnostics
    commands:
      - label: Auth daemon processes (trustd, ctkd, coreauthd)
        command: 'ps -axo pid,uid,ppid,command | egrep ''trustd|ctkd|coreauthd'' | grep -v grep'
        trust: safe
      - label: Kill orphan auth daemons
        command: 'sudo killall -9 trustd ctkd coreauthd secd contactsd && echo ''killed orphans'''
        trust: destructive
      - label: List running apps
        command: 'CONSOLE_USER=$(stat -f "%Su" /dev/console); if [ "$CONSOLE_USER" = "root" ] || [ -z "$CONSOLE_USER" ]; then echo "No user logged in (login window)"; else UID=$(id -u "$CONSOLE_USER" 2>/dev/null || true); APPS=""; [ -n "$UID" ] && APPS=$(sudo launchctl asuser "$UID" sudo -u "$CONSOLE_USER" osascript -e "tell application \"System Events\" to get name of every application process whose visible is true" 2>/dev/null || true); if [ -n "$APPS" ]; then echo "$APPS"; else echo "GUI query unavailable; showing process list for $CONSOLE_USER"; ps -axo user,comm | awk -v u="$CONSOLE_USER" ''$1==u {print $2}'' | sed ''s#.*/##'' | sort -u | head -50; fi; fi'
        trust: safe
      - label: List package receipts (first 120)
        command: 'pkgutil --pkgs | head -120'
        trust: safe
      - label: Forget package receipt (template)
        command: 'echo ''Safety: run manually with exact identifier:''; echo ''sudo pkgutil --forget <PACKAGE_IDENTIFIER>'''
        trust: destructive
      - label: System extensions (non-Apple)
        command: 'systemextensionsctl list 2>/dev/null | grep -v com.apple || echo ''No third-party system extensions loaded'''
        trust: safe
      - label: Studio Display firmware
        command: 'system_profiler SPDisplaysDataType | grep ''Display Firmware Version'''
        trust: safe
      - label: Kill and delete Nudge
        command: 'sudo killall Nudge 2>/dev/null; sudo rm -rf /Applications/Utilities/Nudge.app && echo ''Nudge removed'''
        trust: destructive
      - label: Forget all preferred WiFi networks
        command: 'sudo networksetup -removeallpreferredwirelessnetworks en1 && echo ''All preferred networks forgotten'''
        trust: caution
      - label: XProtect version
        command: 'system_profiler SPInstallHistoryDataType | grep -A2 XProtect'
        trust: safe
      - label: List loaded system extensions
        command: systemextensionsctl list
        trust: safe
      - label: Firmware password check
        command: 'if [ "$(uname -m)" = "arm64" ]; then echo ''N/A on Apple Silicon''; elif command -v firmwarepasswd >/dev/null 2>&1; then sudo firmwarepasswd -check; else echo ''firmwarepasswd unavailable''; fi'
        trust: safe
  - name: Logs
    commands:
      - label: Munki install log (today)
        command: 'RESULT=$(cat "/Library/Managed Installs/Logs/Install.log" 2>/dev/null | grep "$(date +\''%Y-%m-%d\'')"); [ -n "$RESULT" ] && echo "$RESULT" || echo "No installs today"'
        trust: safe
      - label: Munki update log (today)
        command: 'RESULT=$(cat "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log" 2>/dev/null | grep "$(date +\''%Y-%m-%d\'')"); [ -n "$RESULT" ] && echo "$RESULT" || echo "No Munki activity logged today"'
        trust: safe
      - label: Munki update log (full)
        command: 'cat "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log" | tail -100'
        trust: safe
      - label: Check imaging manifest sequence
        command: 'cat "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log" | grep ''Getting manifest'''
        trust: safe
      - label: Outset root log
        command: 'ROOT=/usr/local/outset/logs/outset.log; LEGACY=/var/log/outset.log; if [ -s "$ROOT" ]; then echo "== $ROOT =="; sudo tail -n 200 "$ROOT"; elif [ -s "$LEGACY" ]; then echo "== $LEGACY (legacy) =="; sudo tail -n 200 "$LEGACY"; else echo "No Outset root log found at $ROOT"; fi'
        trust: safe
      - label: Outset user log
        command: 'LOGS=$(find /Users -maxdepth 4 -type f -path "*/Library/Logs/outset.log" 2>/dev/null); if [ -n "$LOGS" ]; then printf "%s\n" "$LOGS" | while IFS= read -r f; do echo "== $f =="; if [ -s "$f" ]; then sudo tail -n 200 "$f"; else echo ''(file exists but is empty)''; fi; echo; done; else echo ''No user Outset logs found under /Users/*/Library/Logs/outset.log''; fi'
        trust: safe
      - label: Outset logs (all known locations)
        command: 'FOUND=0; ROOT=/usr/local/outset/logs/outset.log; LEGACY=/var/log/outset.log; for f in "$ROOT" "$LEGACY"; do if [ -s "$f" ]; then echo "== $f =="; sudo tail -n 200 "$f"; echo; FOUND=1; fi; done; LOGS=$(find /Users -maxdepth 4 -type f -path "*/Library/Logs/outset.log" 2>/dev/null); if [ -n "$LOGS" ]; then FOUND=1; printf "%s\n" "$LOGS" | while IFS= read -r f; do echo "== $f =="; tail -n 200 "$f" 2>/dev/null || sudo tail -n 200 "$f"; echo; done; fi; [ $FOUND -eq 1 ] || echo "No Outset logs found at /usr/local/outset/logs/outset.log or /Users/*/Library/Logs/outset.log"'
        trust: safe
      - label: Outset unified log (last 2h)
        command: 'sudo log show --last 2h --style compact --predicate ''subsystem == "io.macadmins.Outset"'' 2>/dev/null | tail -200'
        trust: safe
      - label: Outset log context around errors
        command: 'FOUND=0; ROOT=/usr/local/outset/logs/outset.log; LEGACY=/var/log/outset.log; for f in "$ROOT" "$LEGACY"; do if [ -s "$f" ]; then echo "== $f =="; if sudo grep -qiE "error|fail|exception" "$f"; then sudo grep -niE -B3 -A3 "error|fail|exception" "$f"; else echo "No error/fail lines found"; fi; echo; FOUND=1; fi; done; LOGS=$(find /Users -maxdepth 4 -type f -path "*/Library/Logs/outset.log" 2>/dev/null); if [ -n "$LOGS" ]; then FOUND=1; printf "%s\n" "$LOGS" | while IFS= read -r f; do echo "== $f =="; if sudo grep -qiE "error|fail|exception" "$f"; then sudo grep -niE -B3 -A3 "error|fail|exception" "$f"; else echo "No error/fail lines found"; fi; echo; done; fi; [ $FOUND -eq 1 ] || echo "No Outset logs found"'
        trust: safe
      - label: System log (recent 100 lines)
        command: 'sudo log show --last 1h --style compact 2>/dev/null | tail -100'
        trust: safe
      - label: Errors and faults (last hour)
        command: 'sudo log show --last 1h --style compact --predicate ''messageType == error OR messageType == fault'' 2>/dev/null | tail -50'
        trust: safe
      - label: Search package receipts (ca.ecuad)
        command: 'pkgutil --pkgs | grep ''^ca.ecuad'' || echo ''No ca.ecuad receipts found'''
        trust: safe
      - label: Forget package receipt (template)
        command: 'echo ''Safety: run manually with exact identifier:''; echo ''sudo pkgutil --forget <PACKAGE_IDENTIFIER>'''
        trust: destructive
  - name: Power
    commands:
      - label: Restart in 1 minute
        command: 'sudo shutdown -r +1 ''Restarting in 1 minute'''
        trust: destructive
      - label: Restart now
        command: sudo shutdown -r now
        trust: destructive
      - label: Sleep now
        command: sudo pmset sleepnow
        trust: destructive
      - label: Power settings
        command: /usr/bin/pmset -g
        trust: safe
      - label: Scheduled wake/sleep/shutdown
        command: sudo pmset -g sched
        trust: safe
      - label: Cancel all scheduled events
        command: 'sudo pmset schedule cancelall && echo ''All schedules cancelled'''
        trust: caution
      - label: Battery status
        command: /usr/bin/pmset -g batt
        trust: safe
      - label: Restore default power settings
        command: sudo pmset restoredefaults
        trust: caution
  - name: Adobe
    commands:
      - label: Creative Cloud version
        command: 'defaults read ''/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app/Contents/Info.plist'' CFBundleShortVersionString 2>/dev/null || echo ''CC not installed'''
        trust: safe
      - label: Check CC app versions
        command: 'defaults read ''/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app/Contents/Info.plist'' CFBundleVersion 2>/dev/null; defaults read ''/Applications/Adobe Acrobat DC/Adobe Acrobat.app/Contents/Info.plist'' CFBundleVersion 2>/dev/null'
        trust: safe
      - label: Update CC with RUM
        command: 'if [ -x /usr/local/bin/remoteupdatemanager ]; then RUM=/usr/local/bin/remoteupdatemanager; else RUM=$(find /usr/local /Library/Application\ Support/Adobe -iname remoteupdatemanager -type f 2>/dev/null | head -1); fi; if [ -n "$RUM" ]; then echo "Starting Adobe RemoteUpdateManager: $RUM"; sudo "$RUM"; STATUS=$?; echo "RemoteUpdateManager finished with exit code $STATUS"; exit $STATUS; else echo "RemoteUpdateManager not installed"; fi'
        trust: caution
      - label: Read RUM update log
        command: 'LOG=$(find /Users -maxdepth 4 -type f -path "*/Library/Logs/RemoteUpdateManager.log" 2>/dev/null | head -1); [ -n "$LOG" ] && tail -20 "$LOG" || echo "RUM log not found"'
        trust: safe
      - label: Clear Adobe SL cache (fix licensing)
        command: 'sudo rm -rf ''/Library/Application Support/Adobe/SLCache'' ''/Library/Application Support/Adobe/SLStore'' ''/Library/Application Support/Adobe/SLStore_v1'' && echo ''SL cache cleared'''
        trust: destructive
      - label: Uninstall Adobe Acrobat DC
        command: 'sudo ''/Applications/Adobe Acrobat DC/Adobe Acrobat.app/Contents/Helpers/Acrobat Uninstaller.app/Contents/Library/LaunchServices/com.adobe.Acrobat.RemoverTool'' Uninstall ''/Applications/Adobe Acrobat DC/Adobe Acrobat.app'''
        trust: safe
  - name: Outset
    commands:
      - label: Read outset log
        command: 'FOUND=0; ROOT=/usr/local/outset/logs/outset.log; LEGACY=/var/log/outset.log; for f in "$ROOT" "$LEGACY"; do if [ -s "$f" ]; then echo "== $f =="; sudo tail -n 200 "$f"; echo; FOUND=1; fi; done; LOGS=$(find /Users -maxdepth 4 -type f -path "*/Library/Logs/outset.log" 2>/dev/null); if [ -n "$LOGS" ]; then FOUND=1; printf "%s\n" "$LOGS" | while IFS= read -r f; do echo "== $f =="; tail -n 200 "$f" 2>/dev/null || sudo tail -n 200 "$f"; echo; done; fi; [ $FOUND -eq 1 ] || echo "No Outset logs found at /usr/local/outset/logs/outset.log or /Users/*/Library/Logs/outset.log"'
        trust: safe
      - label: List Outset scripts (all stages)
        command: 'BASE=/usr/local/outset; STAGES="boot-once boot-every login-once login-every login-privileged-once login-privileged-every on-demand"; if [ ! -d "$BASE" ]; then echo ''Outset base not found: /usr/local/outset''; exit 0; fi; for s in $STAGES; do d="$BASE/$s"; echo "== $s =="; if [ -d "$d" ]; then ls -1 "$d" 2>/dev/null || true; else echo ''(missing)''; fi; echo; done'
        trust: safe
      - label: List login scripts (all login stages)
        command: 'for d in /usr/local/outset/login-every /usr/local/outset/login-once /usr/local/outset/login-privileged-every /usr/local/outset/login-privileged-once; do echo "== $d =="; if [ -d "$d" ]; then ls -1 "$d" 2>/dev/null || true; else echo ''(missing)''; fi; echo; done'
        trust: safe
      - label: List login scripts (detailed)
        command: 'for d in /usr/local/outset/login-every /usr/local/outset/login-once /usr/local/outset/login-privileged-every /usr/local/outset/login-privileged-once; do echo "== $d =="; if [ -d "$d" ]; then find "$d" -maxdepth 1 -type f -exec ls -lh {} \; 2>/dev/null | sort || echo ''(no files)''; else echo ''(missing)''; fi; echo; done'
        trust: safe
      - label: List boot scripts (boot-once/boot-every)
        command: 'for d in /usr/local/outset/boot-once /usr/local/outset/boot-every; do echo "== $d =="; if [ -d "$d" ]; then ls -1 "$d" 2>/dev/null || true; else echo ''(missing)''; fi; echo; done'
        trust: safe
      - label: List on-demand scripts (detailed)
        command: 'd=/usr/local/outset/on-demand; echo "== $d =="; if [ -d "$d" ]; then find "$d" -maxdepth 1 -type f -exec ls -lh {} \; 2>/dev/null | sort || echo ''(no files)''; else echo ''(missing)''; fi'
        trust: safe
      - label: Run login scripts (login-every/login-once)
        command: 'if [ -x /usr/local/outset/outset ]; then sudo /usr/local/outset/outset --login; else echo ''Outset binary not found: /usr/local/outset/outset''; fi'
        trust: caution
      - label: Run login-once scripts (if supported)
        command: 'if [ ! -x /usr/local/outset/outset ]; then echo ''Outset binary not found: /usr/local/outset/outset''; elif /usr/local/outset/outset --help 2>&1 | grep -q -- ''--login-once''; then sudo /usr/local/outset/outset --login-once; else echo ''--login-once not supported by this Outset version; use --login''; fi'
        trust: caution
      - label: Run on-demand scripts
        command: 'sudo touch /private/tmp/.io.macadmins.outset.ondemand.launchd && echo ''On-demand trigger set'''
        trust: caution
      - label: Run on-demand scripts (direct)
        command: 'if [ ! -x /usr/local/outset/outset ]; then echo ''Outset binary not found: /usr/local/outset/outset''; elif /usr/local/outset/outset --help 2>&1 | grep -q -- ''--on-demand''; then sudo /usr/local/outset/outset --on-demand; else sudo touch /private/tmp/.io.macadmins.outset.ondemand.launchd && echo ''--on-demand not supported; trigger file set instead''; fi'
        trust: caution
      - label: Run boot scripts
        command: sudo /usr/local/outset/outset --boot
        trust: caution
      - label: List login-every scripts
        command: 'if [ -d /usr/local/outset/login-every ]; then ls -1 /usr/local/outset/login-every; else echo ''No /usr/local/outset/login-every directory''; fi'
        trust: safe
      - label: Clear login-once scripts
        command: 'sudo rm -rf /usr/local/outset/login-once/* && echo ''Login-once cleared'''
        trust: destructive
      - label: Fix outset permissions
        command: 'sudo chown root:wheel /usr/local/outset && sudo chown -R root:wheel /usr/local/outset/* && sudo chmod -R 755 /usr/local/outset/* && echo ''Permissions fixed'''
        trust: caution
"""#
}
