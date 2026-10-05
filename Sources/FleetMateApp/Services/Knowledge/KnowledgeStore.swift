import Foundation
import FleetMateCore

/// The Handbook and the shared agent skills, from FleetMate's own copies of
/// their repositories. Each copy is always the remote's `main` — never the
/// person's checkout, which may be on a branch or behind — and is refreshed
/// at launch and every fifteen minutes, so what FleetMate shows is never
/// older than that.
@MainActor
final class KnowledgeStore: ObservableObject {
    @Published private(set) var handbook = HandbookIndex(pages: [])
    @Published private(set) var skills = SkillCatalog(entries: [])
    @Published private(set) var handbookSyncedAt: Date?
    @Published private(set) var skillsSyncedAt: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncError: String?
    /// The page shown in the reader sheet. A catalog entry is swapped for the
    /// full page, read from FleetMate's copy, as it opens.
    @Published var openPage: HandbookPage? {
        didSet {
            guard let page = openPage, page.isSummary, let root = handbookContentRoot,
                  let full = HandbookIndex.fullPage(relativePath: page.path, contentRoot: root) else { return }
            openPage = full
        }
    }
    private var handbookContentRoot: URL?

    private var handbookMirror: RepoMirror?
    private var hubMirror: RepoMirror?
    private var siteURL: String?
    private var loop: Task<Void, Never>?

    static let refreshInterval: TimeInterval = 15 * 60

    var isHandbookConfigured: Bool { handbookMirror != nil }
    var isSkillsConfigured: Bool { hubMirror != nil }

    func configure(_ config: FleetMateConfig) {
        // The DevOps sign-in only ever goes to the DevOps server.
        let devOpsHost = URL(string: config.effectiveDevopsBaseUrl)?.host
        handbookMirror = config.handbookRepoUrl.map {
            RepoMirror(name: "handbook", remoteURL: $0, paths: ["website/content", "website/data"], tokenHost: devOpsHost)
        }
        hubMirror = config.agentsHubRepoUrl.map {
            RepoMirror(name: "agents-hub", remoteURL: $0, paths: ["agents"], tokenHost: devOpsHost)
        }
        siteURL = config.handbookSiteUrl
    }

    /// Show what is already on disk at once, then keep it current.
    func start(token: @escaping () async -> String?) {
        guard loop == nil else { return }
        loop = Task {
            await loadFromDisk()
            while !Task.isCancelled {
                await sync(token: await token())
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    func sync(token: String?) async {
        isSyncing = true
        defer { isSyncing = false }
        var errors: [String] = []
        if let mirror = handbookMirror {
            do {
                try await mirror.sync(bearerToken: token)
                handbookSyncedAt = Date()
                await loadHandbook(mirror)
            } catch {
                errors.append("Handbook: \(error.localizedDescription)")
            }
        }
        if let mirror = hubMirror {
            do {
                try await mirror.sync(bearerToken: token)
                skillsSyncedAt = Date()
                await loadSkills(mirror)
            } catch {
                errors.append("Skills: \(error.localizedDescription)")
            }
        }
        if hubMirror == nil { await loadSkills(nil) }
        syncError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if let syncError { dbg.warn("Knowledge sync: \(syncError)", category: "knowledge") }
    }

    private func loadFromDisk() async {
        if let mirror = handbookMirror, await mirror.isCloned { await loadHandbook(mirror) }
        if let mirror = hubMirror, await mirror.isCloned { await loadSkills(mirror) } else { await loadSkills(nil) }
    }

    private func loadHandbook(_ mirror: RepoMirror) async {
        let content = mirror.localURL.appendingPathComponent("website/content")
        let catalogURL = mirror.localURL.appendingPathComponent("website/data/catalog.json")
        handbookContentRoot = content
        // The pipeline's catalog loads in milliseconds; parsing every page is
        // the fallback for a Handbook that does not publish one yet.
        handbook = await Task.detached(priority: .utility) {
            HandbookIndex.loadCatalog(catalogURL) ?? HandbookIndex.load(contentRoot: content)
        }.value
        dbg.info("Handbook index: \(handbook.pages.count) pages", category: "knowledge")
    }

    private func loadSkills(_ mirror: RepoMirror?) async {
        let root = mirror?.localURL
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        skills = await Task.detached(priority: .utility) {
            let shared = root.map { SkillCatalog.load(hubRoot: $0).entries } ?? []
            return SkillCatalog(entries: shared + SkillCatalog.loadLocal(claudeHome: home))
        }.value
    }

    /// This Mac's own skills change when the person edits them; reread on demand.
    func reloadLocalSkills() async { await loadSkills(hubMirror) }

    /// The published page, when the site address is configured.
    func siteURL(for page: HandbookPage) -> URL? {
        guard let siteURL, var base = URL(string: siteURL) else { return nil }
        for part in page.sitePath.split(separator: "/") { base.appendPathComponent(String(part)) }
        return base
    }
}
