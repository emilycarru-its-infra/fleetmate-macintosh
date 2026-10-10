import SwiftUI
import FleetMateCore

// Ported from MunkiStudio (Apache-2.0),
// Sources/App/Features/Git/GitCommitActionSheet.swift. This first port keeps
// the actions that only add history (tag, branch, cherry-pick, revert) or
// move HEAD (checkout); merge, rebase, reset and message editing rewrite or
// discard history and come later. `newBranch` is FleetMate's: create a
// branch at HEAD and switch to it.

/// A commit context-menu action awaiting confirmation / input.
enum CommitAction: Identifiable {
    case addTag(GitCommit)
    case createBranch(GitCommit)
    case checkout(GitCommit)
    case cherryPick(GitCommit)
    case revert(GitCommit)
    /// Create a branch at `commit` (HEAD) and switch to it.
    case newBranch(GitCommit)

    var commit: GitCommit {
        switch self {
        case .addTag(let c), .createBranch(let c), .checkout(let c),
             .cherryPick(let c), .revert(let c), .newBranch(let c):
            return c
        }
    }

    var id: String {
        switch self {
        case .addTag: "tag-\(commit.sha)"
        case .createBranch: "branch-\(commit.sha)"
        case .checkout: "checkout-\(commit.sha)"
        case .cherryPick: "pick-\(commit.sha)"
        case .revert: "revert-\(commit.sha)"
        case .newBranch: "newbranch-\(commit.sha)"
        }
    }
}

/// What the sheet hands back once the user confirms.
enum CommitActionRequest {
    case addTag(commit: GitCommit, name: String, message: String)
    case createBranch(commit: GitCommit, name: String)
    case checkout(GitCommit)
    case cherryPick(GitCommit)
    case revert(GitCommit)
    case newBranch(commit: GitCommit, name: String)
}

/// Confirmation / input popover for a commit context-menu action.
struct GitCommitActionSheet: View {
    let action: CommitAction
    let currentBranch: String?
    let perform: (CommitActionRequest) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tagName = ""
    @State private var tagMessage = ""
    @State private var branchName = ""
    @State private var running = false

    private var branch: String { currentBranch ?? "the current branch" }
    private var shortSHA: String { String(action.commit.sha.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(confirmLabel, role: isDestructive ? .destructive : nil) {
                    guard let request else { return }
                    Task {
                        running = true
                        await perform(request)
                        running = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm || running)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch action {
        case .addTag:
            Text("Tag commit \(shortSHA).")
                .font(.callout).foregroundStyle(.secondary)
            field("Tag name", "v1.0.0", $tagName)
            field("Message (optional — annotated tag)", "Release notes…", $tagMessage)
        case .createBranch:
            Text("Create a branch pointing at commit \(shortSHA).")
                .font(.callout).foregroundStyle(.secondary)
            field("Branch name", "feature/my-change", $branchName)
        case .checkout:
            Text("Check out commit \(shortSHA). This detaches HEAD — you won't be on a branch.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .cherryPick:
            Text("Apply commit \(shortSHA) on top of \(branch).")
                .font(.callout).foregroundStyle(.secondary)
        case .revert:
            Text("Create a new commit that undoes \(shortSHA).")
                .font(.callout).foregroundStyle(.secondary)
        case .newBranch:
            Text("Create a branch from \(branch) and switch to it.")
                .font(.callout).foregroundStyle(.secondary)
            field("Branch name", "feature/my-change", $branchName)
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private var title: String {
        switch action {
        case .addTag: "Add Tag"
        case .createBranch: "Create Branch"
        case .checkout: "Checkout Commit"
        case .cherryPick: "Cherry-Pick Commit"
        case .revert: "Revert Commit"
        case .newBranch: "New Branch"
        }
    }

    private var confirmLabel: String {
        switch action {
        case .addTag: "Add Tag"
        case .createBranch: "Create"
        case .checkout: "Checkout"
        case .cherryPick: "Cherry-Pick"
        case .revert: "Revert"
        case .newBranch: "Create and Switch"
        }
    }

    private var isDestructive: Bool { false }

    private var canConfirm: Bool {
        switch action {
        case .addTag: !tagName.trimmingCharacters(in: .whitespaces).isEmpty
        case .createBranch, .newBranch: !branchName.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }

    private var request: CommitActionRequest? {
        switch action {
        case .addTag(let c):
            .addTag(commit: c,
                    name: tagName.trimmingCharacters(in: .whitespaces),
                    message: tagMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        case .createBranch(let c):
            .createBranch(commit: c, name: branchName.trimmingCharacters(in: .whitespaces))
        case .checkout(let c): .checkout(c)
        case .cherryPick(let c): .cherryPick(c)
        case .revert(let c): .revert(c)
        case .newBranch(let c):
            .newBranch(commit: c, name: branchName.trimmingCharacters(in: .whitespaces))
        }
    }
}
