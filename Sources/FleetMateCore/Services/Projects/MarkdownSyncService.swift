import Foundation

/// Service to sync tasks bidirectionally with Markdown files.
/// Uses a simple markdown format for task representation.
public actor MarkdownSyncService {
    private let config: MarkdownSyncConfig
    
    public var isEnabled: Bool {
        config.enabled && config.repoPath != nil && !config.repoPath!.isEmpty
    }
    
    private var boardsFilePath: String? {
        guard let repoPath = config.repoPath else { return nil }
        return (repoPath as NSString).appendingPathComponent(config.boardsPath).appending("/tasks.md")
    }
    
    public init(config: FleetMateConfig) {
        self.config = config.tasks?.markdown ?? MarkdownSyncConfig()
    }
    
    /// Write tasks to a markdown file.
    public func writeTasks(_ tasks: [UnifiedTask]) async throws -> SyncResult {
        guard isEnabled, let filePath = boardsFilePath else {
            return SyncResult(success: false, message: "Markdown sync not enabled")
        }
        
        var lines: [String] = []
        lines.append("# FleetMate Tasks")
        lines.append("")
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append("_Last synced: \(formatter.string(from: Date()))_")
        lines.append("")
        
        // Group by provider
        let grouped = Dictionary(grouping: tasks) { $0.provider }
        
        for provider in grouped.keys.sorted() {
            guard let providerTasks = grouped[provider] else { continue }
            
            lines.append("## \(getProviderDisplayName(provider))")
            lines.append("")
            
            // Group by bucket within provider
            let byBucket = Dictionary(grouping: providerTasks) { $0.bucket ?? "Uncategorized" }
            
            for bucket in byBucket.keys.sorted() {
                guard let bucketTasks = byBucket[bucket] else { continue }
                
                lines.append("### \(bucket)")
                lines.append("")
                
                let sortedTasks = bucketTasks.sorted { 
                    ($0.state.rawValue, $0.createdAt) < 
                    ($1.state.rawValue, $1.createdAt)
                }
                
                for task in sortedTasks {
                    lines.append(formatTask(task))
                    if let description = task.description, !description.isEmpty {
                        let desc = description.count > 200 
                            ? String(description.prefix(200)) + "..." 
                            : description
                        lines.append("  > \(escapeMarkdown(desc.replacingOccurrences(of: "\n", with: " ")))")
                    }
                }
                
                lines.append("")
            }
        }
        
        // Ensure directory exists
        let url = URL(fileURLWithPath: filePath)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
        
        print("Markdown: Wrote \(tasks.count) tasks to \(filePath)")
        
        return SyncResult(
            success: true,
            message: "Wrote \(tasks.count) tasks to \(filePath)"
        )
    }
    
    /// Read tasks from a markdown file.
    public func readTasks() async throws -> [UnifiedTask] {
        guard isEnabled, let filePath = boardsFilePath else {
            return []
        }
        
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            return []
        }
        
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: CharacterSet.newlines)
        
        var tasks: [UnifiedTask] = []
        var currentProvider: String?
        var currentBucket: String?
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            
            // Provider header
            if trimmed.hasPrefix("## ") {
                currentProvider = parseProviderFromHeader(String(trimmed.dropFirst(3)))
                continue
            }
            
            // Bucket header
            if trimmed.hasPrefix("### ") {
                currentBucket = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            
            // Task line
            if trimmed.hasPrefix("- [") {
                if let task = parseTask(line: trimmed, provider: currentProvider, bucket: currentBucket) {
                    tasks.append(task)
                }
            }
        }
        
        print("Markdown: Read \(tasks.count) tasks from \(filePath)")
        return tasks
    }
    
    /// Sync tasks bidirectionally - merge changes from both sources.
    public func syncBidirectional(providerTasks: [UnifiedTask]) async throws -> SyncResult {
        guard isEnabled else {
            return SyncResult(success: false, message: "Markdown sync not enabled")
        }
        
        var result = SyncResult()
        
        // Read existing tasks from markdown
        let markdownTasks = try await readTasks()
        let providerKeys = Set(providerTasks.map { "\($0.provider):\($0.id)" })
        
        // Merge: provider tasks are authoritative for existing items
        // but markdown may have local-only tasks
        var mergedTasks = providerTasks
        
        // Find tasks that exist only in markdown (local-only)
        for mdTask in markdownTasks {
            let key = "\(mdTask.provider):\(mdTask.id)"
            if !providerKeys.contains(key) && mdTask.provider == "local" {
                mergedTasks.append(mdTask)
                result.created += 1
            }
        }
        
        // Write merged tasks back
        let writeResult = try await writeTasks(mergedTasks)
        result.success = writeResult.success
        result.message = "Synced \(mergedTasks.count) tasks (\(result.created) local-only preserved)"
        
        return result
    }
    
    // MARK: - Formatting
    
    private func formatTask(_ task: UnifiedTask) -> String {
        let checkbox: String
        switch task.state {
        case .closed: checkbox = "[x]"
        case .inProgress: checkbox = "[-]"
        case .open: checkbox = "[ ]"
        }
        
        var parts: [String] = []
        parts.append("- \(checkbox) **\(escapeMarkdown(task.title))**")
        
        if !task.labels.isEmpty {
            parts.append(task.labels.map { "`\($0)`" }.joined(separator: " "))
        }
        
        if let priority = task.priority {
            parts.append("!\(priority)")
        }
        
        if let dueDate = task.dueDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            parts.append("📅 \(formatter.string(from: dueDate))")
        }
        
        if !task.assignees.isEmpty {
            parts.append(task.assignees.map { "@\($0)" }.joined(separator: " "))
        }
        
        if let url = task.externalUrl, !url.isEmpty {
            parts.append("[\(task.provider)#\(task.id)](\(url))")
        } else {
            parts.append("[\(task.provider)#\(task.id)]")
        }
        
        return parts.joined(separator: " ")
    }
    
    private func parseTask(line: String, provider: String?, bucket: String?) -> UnifiedTask? {
        // Pattern: - [x] **Title** `label` !priority 📅 2024-01-01 @user [provider#id](url)
        guard let match = line.range(of: #"^- \[(.)\] \*\*(.+?)\*\*(.*)$"#, options: .regularExpression) else {
            return nil
        }
        
        let fullMatch = String(line[match])
        
        // Extract checkbox state
        guard let checkRange = fullMatch.range(of: #"\[(.)\]"#, options: .regularExpression),
              let checkChar = fullMatch[checkRange].dropFirst().dropLast().first else {
            return nil
        }
        
        let state: TaskState
        switch checkChar {
        case "x", "X": state = .closed
        case "-": state = .inProgress
        default: state = .open
        }
        
        // Extract title
        guard let titleRange = fullMatch.range(of: #"\*\*(.+?)\*\*"#, options: .regularExpression) else {
            return nil
        }
        let title = unescapeMarkdown(String(fullMatch[titleRange].dropFirst(2).dropLast(2)))
        
        let rest = String(fullMatch[titleRange.upperBound...])
        
        // Parse labels
        var labels: [String] = []
        let labelPattern = #"`([^`]+)`"#
        if let regex = try? NSRegularExpression(pattern: labelPattern) {
            let nsRange = NSRange(rest.startIndex..., in: rest)
            let matches = regex.matches(in: rest, range: nsRange)
            for match in matches {
                if let range = Range(match.range(at: 1), in: rest) {
                    labels.append(String(rest[range]))
                }
            }
        }
        
        // Parse priority
        var priority: Int?
        if let priorityRange = rest.range(of: #"!(\d+)"#, options: .regularExpression) {
            let priorityStr = String(rest[priorityRange].dropFirst())
            priority = Int(priorityStr)
        }
        
        // Parse due date
        var dueDate: Date?
        if let dueDateRange = rest.range(of: #"📅\s*(\d{4}-\d{2}-\d{2})"#, options: .regularExpression) {
            let dateStr = rest[dueDateRange].replacingOccurrences(of: "📅", with: "").trimmingCharacters(in: .whitespaces)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            dueDate = formatter.date(from: dateStr)
        }
        
        // Parse assignees
        var assignees: [String] = []
        let assigneePattern = #"@(\w+)"#
        if let regex = try? NSRegularExpression(pattern: assigneePattern) {
            let nsRange = NSRange(rest.startIndex..., in: rest)
            let matches = regex.matches(in: rest, range: nsRange)
            for match in matches {
                if let range = Range(match.range(at: 1), in: rest) {
                    assignees.append(String(rest[range]))
                }
            }
        }
        
        // Parse source reference
        var parsedProvider = provider ?? "local"
        var id = UUID().uuidString.prefix(8).lowercased()
        var url: String?
        
        if let sourceRange = rest.range(of: #"\[(\w+)#(\d+)\](?:\(([^)]+)\))?"#, options: .regularExpression) {
            let sourceMatch = String(rest[sourceRange])
            if let providerRange = sourceMatch.range(of: #"(\w+)#"#, options: .regularExpression) {
                parsedProvider = String(sourceMatch[providerRange].dropLast())
            }
            if let idRange = sourceMatch.range(of: #"#(\d+)"#, options: .regularExpression) {
                id = String(sourceMatch[idRange].dropFirst())
            }
            if let urlRange = sourceMatch.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
                url = String(sourceMatch[urlRange].dropFirst().dropLast())
            }
        }
        
        return UnifiedTask(
            id: String(id),
            provider: parsedProvider,
            title: title,
            description: nil,
            state: state,
            assignees: assignees,
            labels: labels,
            bucket: bucket,
            dueDate: dueDate,
            createdAt: Date(),
            updatedAt: Date(),
            closedAt: nil,
            externalUrl: url,
            priority: priority
        )
    }
    
    private func getProviderDisplayName(_ provider: String) -> String {
        switch provider {
        case "azdo", "azure-devops": return "Azure DevOps"
        case "github": return "GitHub"
        case "gitea": return "Gitea"
        case "local": return "Local Tasks"
        default: return provider
        }
    }
    
    private func parseProviderFromHeader(_ header: String) -> String {
        switch header.trimmingCharacters(in: .whitespaces).lowercased() {
        case "azure devops": return "azdo"
        case "github": return "github"
        case "gitea": return "gitea"
        case "local tasks": return "local"
        default: return header.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }
    
    private func escapeMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
    
    private func unescapeMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "\\*", with: "*")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
