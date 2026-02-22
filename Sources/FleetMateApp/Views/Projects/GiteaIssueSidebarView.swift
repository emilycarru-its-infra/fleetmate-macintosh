import SwiftUI
import FleetMateCore

/// Sidebar for Gitea issues.
struct GiteaIssueSidebarView: View {
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

                Text("Gitea")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let url = task.externalUrl, let urlObj = URL(string: url) {
                    Link(destination: urlObj) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open in Gitea")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    Text(task.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    // State + bucket
                    HStack(spacing: 8) {
                        StateBadge(state: task.state)
                        if let bucket = task.bucket {
                            Text(bucket)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(6)
                        }
                    }

                    Divider()

                    // Assignees
                    if !task.assignees.isEmpty {
                        SidebarSection(title: "Assignees", icon: "person.2") {
                            ForEach(task.assignees, id: \.self) {
                                Text($0).font(.subheadline)
                            }
                        }
                    }

                    // Labels
                    if !task.labels.isEmpty {
                        SidebarSection(title: "Labels", icon: "tag") {
                            FlowLayout(spacing: 4) {
                                ForEach(task.labels, id: \.self) { label in
                                    Text(label)
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.green.opacity(0.12))
                                        .cornerRadius(10)
                                }
                            }
                        }
                    }

                    // Milestone / bucket
                    if let bucket = task.bucket {
                        SidebarSection(title: "Milestone", icon: "flag") {
                            Text(bucket).font(.subheadline)
                        }
                    }

                    // Description
                    if let description = task.description, !description.isEmpty {
                        SidebarSection(title: "Description", icon: "text.alignleft") {
                            MarkdownTextView(content: description)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Dates
                    SidebarSection(title: "Dates", icon: "calendar") {
                        LabeledContent("Created") { Text(task.createdAt, style: .date) }.font(.subheadline)
                        LabeledContent("Updated") { Text(task.updatedAt, style: .date) }.font(.subheadline)
                    }

                    // Open in Gitea
                    if let url = task.externalUrl, let urlObj = URL(string: url) {
                        Link(destination: urlObj) {
                            HStack {
                                Label("Open in Gitea to edit", systemImage: "arrow.triangle.branch")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                        }
                        .font(.subheadline)
                        .padding(10)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}
