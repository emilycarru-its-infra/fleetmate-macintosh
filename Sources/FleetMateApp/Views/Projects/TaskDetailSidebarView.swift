import SwiftUI
import FleetMateCore

/// Routes to the correct provider-specific sidebar based on task.provider.
struct TaskDetailSidebarView: View {
    let task: UnifiedTask
    let ghConfig: GitHubProviderConfig?
    let onClose: () -> Void

    var body: some View {
        switch task.provider {
        case "github":
            GitHubIssueSidebarView(task: task, config: ghConfig, onClose: onClose)
        case "azdo":
            AzDoTaskSidebarView(task: task, onClose: onClose)
        case "gitea":
            GiteaIssueSidebarView(task: task, onClose: onClose)
        default:
            GenericTaskSidebarView(task: task, onClose: onClose)
        }
    }
}

// MARK: - Generic fallback sidebar

struct GenericTaskSidebarView: View {
    let task: UnifiedTask
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Close sidebar")

                Text(task.provider.uppercased())
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let url = task.externalUrl, let urlObj = URL(string: url) {
                    Link(destination: urlObj) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open in browser")
                }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    Text(task.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)

                    // State + bucket
                    HStack(spacing: 8) {
                        StateBadge(state: task.state)
                        if let bucket = task.bucket {
                            Text(bucket)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(6)
                        }
                    }

                    // Labels
                    if !task.labels.isEmpty {
                        SidebarSection(title: "Labels", icon: "tag") {
                            FlowLayout(spacing: 6) {
                                ForEach(task.labels, id: \.self) { label in
                                    Text(label)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.15))
                                        .cornerRadius(10)
                                }
                            }
                        }
                    }

                    // Assignees
                    if !task.assignees.isEmpty {
                        SidebarSection(title: "Assignees", icon: "person.2") {
                            ForEach(task.assignees, id: \.self) { Text($0).font(.subheadline) }
                        }
                    }

                    // Description — render HTML or markdown
                    if let description = task.description, !description.isEmpty {
                        SidebarSection(title: "Description", icon: "text.alignleft") {
                            if description.contains("<") && description.contains(">") {
                                HtmlTextView(html: description)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text((try? AttributedString(markdown: description)) ?? AttributedString(description))
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    // Dates
                    SidebarSection(title: "Dates", icon: "calendar") {
                        LabeledContent("Created") {
                            Text(task.createdAt, style: .date)
                        }
                        .font(.subheadline)
                        LabeledContent("Updated") {
                            Text(task.updatedAt, style: .date)
                        }
                        .font(.subheadline)
                        if let closed = task.closedAt {
                            LabeledContent("Closed") {
                                Text(closed, style: .date)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Shared sidebar components

struct StateBadge: View {
    let state: TaskState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(10)
    }

    private var color: Color {
        switch state {
        case .open: return .green
        case .inProgress: return .blue
        case .closed: return .gray
        }
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }
}
