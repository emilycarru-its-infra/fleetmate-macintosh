import SwiftUI
import UserNotifications
import FleetMateCore

/// The fleet command runner: the library, what is picked, the custom
/// command, history, and per-host results of the run in progress.
extension ManageState {

    // MARK: - Library

    func loadCommandLibrary() {
        let loaded = store.loadCommandLibrary(path: config.commandsPath.isEmpty ? nil : config.resolvedCommandsPath)
        commandCategories = loaded.categories
        if let id = selectedCategoryID, !commandCategories.contains(where: { $0.id == id }) {
            selectedCategoryID = nil
            selectedCommandID = nil
        }
        commandHistory = store.loadHistory()
    }

    var selectedCategory: CommandCategory? {
        guard let id = selectedCategoryID else { return nil }
        return commandCategories.first { $0.id == id }
    }

    var selectedCommand: ManageCommand? {
        guard let id = selectedCommandID, let category = selectedCategory else { return nil }
        return category.commands.first { $0.id == id }
    }

    /// The custom command when there is one, else the picked library command.
    var resolvedCommandString: String {
        let custom = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return selectedCommand?.command ?? ""
    }

    private func saveLibrary() {
        do {
            try CommandLibrary.save(commandCategories, to: config.commandsPath.isEmpty ? store.commandsPath : config.resolvedCommandsPath)
        } catch {
            dbg.error("Could not save command library: \(error.localizedDescription)", category: "manage")
        }
    }

    @discardableResult
    func addCategory(name: String) -> UUID {
        let category = CommandCategory(name: name, commands: [])
        commandCategories.append(category)
        saveLibrary()
        return category.id
    }

    func addCommand(toCategoryID categoryID: UUID, label: String, command: String, trustLevel: CommandTrustLevel) {
        guard let index = commandCategories.firstIndex(where: { $0.id == categoryID }) else { return }
        let entry = ManageCommand(label: label, command: command, trustLevel: trustLevel)
        commandCategories[index].commands.append(entry)
        saveLibrary()
        selectedCategoryID = categoryID
        selectedCommandID = entry.id
        customCommand = ""
    }

    func editCommand(id: UUID, inCategoryID categoryID: UUID, label: String, command: String, trustLevel: CommandTrustLevel) {
        guard let categoryIndex = commandCategories.firstIndex(where: { $0.id == categoryID }),
              let index = commandCategories[categoryIndex].commands.firstIndex(where: { $0.id == id }) else { return }
        commandCategories[categoryIndex].commands[index] = ManageCommand(id: id, label: label, command: command, trustLevel: trustLevel)
        saveLibrary()
    }

    func deleteCommand(id: UUID, fromCategoryID categoryID: UUID) {
        guard let categoryIndex = commandCategories.firstIndex(where: { $0.id == categoryID }) else { return }
        commandCategories[categoryIndex].commands.removeAll { $0.id == id }
        if selectedCommandID == id { selectedCommandID = nil }
        saveLibrary()
    }

    // MARK: - History

    func addToHistory(label: String, command: String) {
        commandHistory = store.addHistory(commandHistory, label: label, command: command)
    }

    func clearHistory() {
        commandHistory = []
        store.clearHistory()
    }

    // MARK: - Results

    var sortedResults: [CommandRunResult] {
        results.values.sorted { $0.computer.displayName.localizedStandardCompare($1.computer.displayName) == .orderedAscending }
    }

    func clearResults() {
        results = [:]
    }

    /// The checked machines that answered the scan; what a run targets.
    private var runTargets: [CommandRunner.Target] {
        onlineSelectedComputers.compactMap { computer in
            guard let ip = ipFor(computer) else { return nil }
            return CommandRunner.Target(computer: computer, ip: ip)
        }
    }

    private func makeRunner() -> CommandRunner {
        CommandRunner(executor: makeExecutor(), concurrency: max(1, config.probeConcurrency), username: config.resolvedSshUser, timeout: 300)
    }

    /// Run whatever is picked or typed on the selected online machines.
    func startCommand() {
        let command = resolvedCommandString
        guard !command.isEmpty else { return }
        run(script: command, label: selectedCommand?.label ?? command, recordHistory: true)
    }

    /// Run a literal script, for quick actions, placeholders and history.
    func runQuickCommand(_ script: String, label: String, recordHistory: Bool = true) {
        run(script: script, label: label, recordHistory: recordHistory)
    }

    private func run(script: String, label: String, recordHistory: Bool) {
        guard !isRunning else { return }
        let targets = runTargets
        guard !targets.isEmpty else { return }
        if recordHistory { addToHistory(label: label, command: script) }
        beginRun(targets: targets, label: label)
        let runner = makeRunner()
        runTask = Task { [weak self] in
            await runner.run(script: script, on: targets) { event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            await MainActor.run { [weak self] in self?.finishRun(label: label) }
        }
    }

    /// Copy a package to the selected online machines and install it.
    func installPackage(at url: URL) {
        guard !isRunning else { return }
        let targets = runTargets
        guard !targets.isEmpty else { return }
        let label = "Install \(url.lastPathComponent)"
        addToHistory(label: label, command: "installer -pkg \(url.lastPathComponent) -target /")
        beginRun(targets: targets, label: label)
        let runner = makeRunner()
        let path = url.path
        runTask = Task { [weak self] in
            await runner.installPackage(localPath: path, on: targets) { event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            await MainActor.run { [weak self] in self?.finishRun(label: label) }
        }
    }

    func killCommand() {
        runTask?.cancel()
        runTask = nil
        for key in results.keys where !(results[key]?.status.isTerminal ?? true) {
            results[key]?.status = .cancelled
            results[key]?.endTime = Date()
        }
        isRunning = false
        runLabel = ""
    }

    private func beginRun(targets: [CommandRunner.Target], label: String) {
        isRunning = true
        runLabel = label
        runStartedAt = Date()
        results = [:]
        for target in targets {
            results[target.computer.id] = CommandRunResult(computer: target.computer, ip: target.ip)
        }
    }

    private func apply(_ event: CommandRunner.Event) {
        switch event {
        case .started(let serial):
            results[serial]?.status = .running
            results[serial]?.startTime = Date()
        case .output(let serial, let chunk):
            guard var result = results[serial], result.status == .running else { return }
            result.output += chunk
            results[serial] = result
        case .finished(let serial, let streamResult):
            guard var result = results[serial], !result.status.isTerminal else { return }
            result.errorOutput = streamResult.stderr
            result.exitCode = streamResult.exitCode
            result.endTime = Date()
            result.status = CommandRunStatus(outcome: streamResult.outcome, exitCode: streamResult.exitCode)
            results[serial] = result
            if streamResult.outcome == .authFailed { sshUnavailable.insert(serial) }
        case .cancelled(let serial):
            guard var result = results[serial], !result.status.isTerminal else { return }
            result.status = .cancelled
            result.endTime = Date()
            results[serial] = result
        }
    }

    private func finishRun(label: String) {
        guard isRunning else { return }
        isRunning = false
        runLabel = ""
        runTask = nil
        notifyIfInBackground(label: label)
    }

    /// A macOS notification when the run finished while FleetMate was not
    /// the frontmost app; in-app the results are already on screen.
    private func notifyIfInBackground(label: String) {
        guard !NSApp.isActive else { return }
        let succeeded = results.values.filter { $0.status == .success }.count
        let failed = results.values.filter { if case .failed = $0.status { return true }; return $0.status == .authFailed || $0.status == .timeout }.count
        let offline = results.values.filter { $0.status == .offline }.count
        let content = UNMutableNotificationContent()
        content.title = "\(label) finished"
        content.body = "\(succeeded) succeeded, \(failed) failed, \(offline) offline"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Quick actions from the Actions menu: what they run, and how they are
/// confirmed. Each is destructive to the user's session, so each asks.
enum ManageQuickAction: String, CaseIterable, Identifiable {
    case restart
    case logOut
    case sleep
    case lockScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restart: "Restart"
        case .logOut: "Log Out User"
        case .sleep: "Sleep"
        case .lockScreen: "Lock Screen"
        }
    }

    var icon: String {
        switch self {
        case .restart: "arrow.clockwise"
        case .logOut: "person.fill.xmark"
        case .sleep: "moon.fill"
        case .lockScreen: "lock.fill"
        }
    }

    func confirmation(count: Int) -> (title: String, message: String) {
        let machines = "\(count) machine\(count == 1 ? "" : "s")"
        switch self {
        case .restart:
            return ("Restart \(machines)?", "This restarts every selected online machine immediately. Unsaved work is lost.")
        case .logOut:
            return ("Log out the current user on \(machines)?", "This logs out whoever is signed in on each machine immediately.")
        case .sleep:
            return ("Sleep \(machines)?", "This puts every selected online machine to sleep immediately.")
        case .lockScreen:
            return ("Lock the screen on \(machines)?", "This locks the screen on every selected online machine.")
        }
    }

    var script: String {
        switch self {
        case .restart:
            return "sudo shutdown -r now"
        case .logOut:
            return "sudo launchctl bootout gui/$(id -u $(stat -f '%Su' /dev/console)) && echo 'User logged out'"
        case .sleep:
            return "sudo pmset sleepnow"
        case .lockScreen:
            return """
            CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null || true)
            if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
              echo 'No logged-in user session to lock'
            elif CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null); then
              if sudo launchctl asuser "$CONSOLE_UID" osascript -e 'tell application "System Events" to keystroke "q" using {control down, command down}' 2>/dev/null; then
                echo "Lock requested for $CONSOLE_USER"
              else
                pmset displaysleepnow
                echo 'Lock keystroke unavailable; display sleep requested'
              fi
            else
              echo "Could not resolve user ID for $CONSOLE_USER"
            fi
            """
        }
    }
}
