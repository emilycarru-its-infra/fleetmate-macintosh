import SwiftUI
import AppKit
import FleetMateCore

// MARK: - Host

/// Puts the lightbox over the window's content: a panel 90% of the window's
/// width and height, centred over a dimmed backdrop. ContentView applies it
/// once; views open it through `@Environment(\.lightbox)` or `AppState`.
struct LightboxHost: ViewModifier {
    @ObservedObject var appState: AppState

    func body(content: Content) -> some View {
        let isOpen = appState.lightboxHistory != nil
        content
            .environment(\.lightbox, LightboxAction { [weak appState] link in appState?.openLightbox(link) })
            // VoiceOver stays inside the lightbox while it is up.
            .accessibilityHidden(isOpen)
            .overlay {
                if let history = appState.lightboxHistory {
                    LightboxOverlay(history: history)
                        .environmentObject(appState)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isOpen)
    }
}

// MARK: - Overlay

private struct LightboxOverlay: View {
    let history: LightboxHistory<FleetMateLink>

    @EnvironmentObject private var appState: AppState
    @FocusState private var panelFocused: Bool
    @AccessibilityFocusState private var voiceOverCrumb: Int?

    private var current: FleetMateLink { history.current }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // The backdrop takes clicks, not focus, and VoiceOver skips it.
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.closeLightbox() }
                    .accessibilityHidden(true)

                panel
                    .frame(width: geo.size.width * 0.9, height: geo.size.height * 0.9)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            LightboxDestinationView(link: current)
                .id(current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        // Links inside open inside: related work items, issues, pull
        // requests, commits and runs join the trail.
        .environment(\.openURL, OpenURLAction { appState.lightboxOpenURL($0) })
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onAppear {
            // After the overlay is in the window, or the focus request is lost.
            DispatchQueue.main.async {
                panelFocused = true
                voiceOverCrumb = history.index
            }
        }
        .onExitCommand { appState.closeLightbox() }
        // Escape closes it from anywhere inside, a text field included.
        .background {
            Button("Close") { appState.closeLightbox() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Lightbox, \(appState.lightboxTitle(for: current))")
    }

    // MARK: Chrome

    private var chrome: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { appState.goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!history.canGoBack)
                .help("Back (⌘[)")
                Button { appState.goForward() } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!history.canGoForward)
                .help("Forward (⌘])")
            }
            .labelStyle(.iconOnly)
            .fixedSize()

            breadcrumbs
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { appState.openInHomeTab(current) } label: {
                Label(homeTabTitle, systemImage: homeTab.icon)
            }
            .help("Close the lightbox and show this in \(homeTab.rawValue)")

            Button { appState.closeLightbox() } label: {
                Label("Close", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help("Close (Esc)")
            .accessibilityLabel("Close lightbox")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Every place in the trail. The current one is bold; places ahead of it,
    /// which Forward returns to, are dimmed.
    private var breadcrumbs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(history.entries.enumerated()), id: \.offset) { position, link in
                        if position > 0 {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        crumb(link, at: position)
                            .id(position)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: history.index) { _, index in
                withAnimation { proxy.scrollTo(index, anchor: .trailing) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Breadcrumbs")
    }

    private func crumb(_ link: FleetMateLink, at position: Int) -> some View {
        let isCurrent = position == history.index
        let title = appState.lightboxTitle(for: link)
        return Button { appState.showLightboxCrumb(at: position) } label: {
            HStack(spacing: 4) {
                Image(systemName: Self.symbol(for: link))
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .appFont(.callout, weight: isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary)
                             : position > history.index ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: 280, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isHeader] : [])
        .accessibilityFocused($voiceOverCrumb, equals: position)
    }

    private var homeTab: AppTab {
        switch current {
        case .workItem, .gitHubIssue: return .projects
        default: return .development
        }
    }

    private var homeTabTitle: String { "Open in \(homeTab.rawValue)" }

    static func symbol(for link: FleetMateLink) -> String {
        switch link {
        case .workItem: return "checklist"
        case .gitHubIssue: return "smallcircle.filled.circle"
        case .pullRequest: return "arrow.triangle.pull"
        case .commit: return "point.topleft.down.to.point.bottomright.curvepath"
        case .azureDevOpsRun, .azureDevOpsPipeline, .gitHubRun: return "play.circle"
        case .device, .asset, .ticket, .user, .group, .reporting: return "link"
        }
    }
}

// MARK: - Destinations

/// The existing detail view for what a link names, loaded by its own loader.
struct LightboxDestinationView: View {
    let link: FleetMateLink
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch link {
        case .workItem(let id):
            AzDoTaskSidebarView(
                task: .workItemStub(id: id, title: appState.lightboxTitle(for: link), config: appState.config),
                service: appState.devOpsService,
                onClose: { appState.closeLightbox() },
                onSelectWorkItem: { appState.openLightbox(.workItem(id: $0)) },
                layout: .wide
            )
        case .gitHubIssue(let owner, let repo, let number):
            GitHubIssueSidebarView(
                task: UnifiedTask(
                    id: String(number),
                    provider: "github",
                    title: "#\(number)",
                    externalUrl: "https://github.com/\(owner)/\(repo)/issues/\(number)"
                ),
                config: appState.config.tasks?.providers.github,
                onClose: { appState.closeLightbox() },
                layout: .wide
            )
        default:
            LightboxDevelopmentDestination(link: link)
        }
    }
}

/// Pull requests, commits and pipeline runs: resolved through the
/// Development tab's resolver (its lists first, then by id), then shown in
/// that tab's detail views.
private struct LightboxDevelopmentDestination: View {
    let link: FleetMateLink
    @EnvironmentObject private var appState: AppState
    @State private var resolved: DevelopmentModel.ResolvedLink?
    @State private var loadError: String?
    @State private var awaitingSignIn = false

    var body: some View {
        Group {
            switch resolved {
            case .pullRequest(let pr):
                PullRequestDetailView(pullRequest: pr, isInline: true) {
                    appState.development.noteActionCompleted(pr, appState: appState)
                }
            case .commit(let selection):
                CommitDetailView(selection: selection)
            case .run(let run):
                PipelineRunDetailView(run: run, model: appState.development) {
                    appState.development.loadPipelines(appState: appState, force: true)
                }
            case nil:
                if awaitingSignIn {
                    DevOpsSignInWaitView(subject: appState.lightboxTitle(for: link), error: loadError)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't Open \(appState.lightboxTitle(for: link))", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Loading \(appState.lightboxTitle(for: link))…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await load() }
        .onDevOpsSignIn(appState) {
            if awaitingSignIn { Task { await load() } }
        }
    }

    private func load() async {
        loadError = nil
        let startedSignedIn = appState.devOpsSsoAuthenticated
        do {
            resolved = try await appState.development.resolve(link, appState: appState)
            awaitingSignIn = false
        } catch {
            let retry: SignInRetry = link.needsAzureDevOps
                ? appState.devOpsRetry(startedSignedIn: startedSignedIn)
                : .showError
            switch retry {
            case .retryNow:
                if let again = try? await appState.development.resolve(link, appState: appState) {
                    resolved = again
                } else {
                    loadError = error.localizedDescription
                }
            case .waitForSignIn:
                awaitingSignIn = true
            case .showError:
                loadError = error.localizedDescription
            }
        }
    }
}

// MARK: - Stubs

extension UnifiedTask {
    /// Enough for the work-item view to load the rest itself: the id, a
    /// title until the item arrives, and the web URL its globe button opens.
    static func workItemStub(id: Int, title: String, config: FleetMateConfig, project: String? = nil) -> UnifiedTask {
        var url: String?
        if let org = config.devopsOrganization,
           let projectPart = (project ?? config.devopsProject)?
               .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            url = "\(config.effectiveDevopsBaseUrl)/\(org)/\(projectPart)/_workitems/edit/\(id)"
        }
        return UnifiedTask(id: String(id), provider: "azdevops", title: title, externalUrl: url)
    }
}
