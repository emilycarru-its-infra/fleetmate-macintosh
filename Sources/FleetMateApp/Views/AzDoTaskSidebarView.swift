import SwiftUI
import FleetMateCore

/// Sidebar for Azure DevOps work items.
/// Shows all available fields (read-only) with a prominent link to open in browser for editing.
struct AzDoTaskSidebarView: View {
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

                Text("DevOps")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let url = task.externalUrl, let urlObj = URL(string: url) {
                    Link(destination: urlObj) {
                        Label("Edit in DevOps", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
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
                        if let priority = task.priority {
                            Label("P\(priority)", systemImage: "flag")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Assignees
                    if !task.assignees.isEmpty {
                        SidebarSection(title: "Assigned To", icon: "person") {
                            ForEach(task.assignees, id: \.self) {
                                Text($0).font(.subheadline)
                            }
                        }
                    }

                    // Labels / Area
                    if !task.labels.isEmpty {
                        SidebarSection(title: "Tags", icon: "tag") {
                            FlowLayout(spacing: 4) {
                                ForEach(task.labels, id: \.self) { label in
                                    Text(label)
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.12))
                                        .cornerRadius(10)
                                }
                            }
                        }
                    }

                    // Description — render HTML from DevOps
                    if let description = task.description, !description.isEmpty {
                        SidebarSection(title: "Description", icon: "text.alignleft") {
                            HtmlTextView(html: description)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }

                    // Dates
                    SidebarSection(title: "Dates", icon: "calendar") {
                        LabeledContent("Created") { Text(task.createdAt, style: .date) }.font(.subheadline)
                        LabeledContent("Updated") { Text(task.updatedAt, style: .date) }.font(.subheadline)
                    }

                    Divider()

                    // Full editing note
                    if let url = task.externalUrl, let urlObj = URL(string: url) {
                        Link(destination: urlObj) {
                            HStack {
                                Label("Open in DevOps to edit", systemImage: "building.2")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                        }
                        .font(.subheadline)
                        .padding(10)
                        .background(Color.blue.opacity(0.08))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}
