import Foundation

/// Graph surfaces used to diagnose configuration management rather than a single
/// device: what changed a directory object, and whether a setting id is real.
public extension GraphService {

    /// Beta endpoints, for the surfaces with no v1.0 equivalent.
    ///
    /// `baseUrl` is v1.0 and every other call is built from it, so a beta
    /// collection needs its own absolute base. Both transports take a full URL,
    /// so this works under `aze` as well as the direct path.
    private var betaUrl: String { "https://graph.microsoft.com/beta" }

    // MARK: - Directory audit log

    /// Read the Entra directory audit log, newest first.
    ///
    /// This answers "what changed this object, and who did it" — the question a
    /// plain lookup cannot. Automation appears as the application holding the
    /// service principal, so an object removed by a lifecycle policy or a
    /// pipeline is attributable here and nowhere else.
    ///
    /// Requires `AuditLog.Read.All`. Without it Graph returns 403 rather than an
    /// empty collection, and the two mean very different things to whoever is
    /// asking, so the failure is allowed to propagate rather than being flattened
    /// into "no results".
    func getDirectoryAudits(filter: String?, limit: Int = 50) async throws -> [DirectoryAuditEvent] {
        guard let headers = await headers() else { return [] }

        var url = "\(baseUrl)/auditLogs/directoryAudits?$top=\(pageSize(for: limit))"
        if let filter, !filter.isEmpty {
            url += "&$filter=\(filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter)"
        }

        var events: [DirectoryAuditEvent] = []

        while let currentUrl = URL(string: url), events.count < limit {
            let response: DirectoryAuditListResponse = try await fetch(
                url: currentUrl.absoluteString, headers: headers)
            events.append(contentsOf: response.value)

            if let nextLink = response.nextLink {
                url = nextLink
            } else {
                break
            }
        }

        // Graph does not guarantee ordering once a $filter is applied, and an
        // audit trail read out of order is actively misleading.
        return Array(
            events
                .sorted { ($0.activityDateTime ?? "") > ($1.activityDateTime ?? "") }
                .prefix(limit))
    }

    // MARK: - Intune Settings Catalog

    /// Search the Settings Catalog definitions.
    ///
    /// Matching runs locally on purpose. The catalog holds tens of thousands of
    /// definitions, its `$filter` support does not cover the fields anyone
    /// actually searches on, and `$search` is not offered on this collection at
    /// all — while the useful term is usually a fragment of the setting id or a
    /// word from its description. So the platform slice, which Graph does
    /// support, is pushed down and the substring match happens here.
    ///
    /// Paging stops as soon as `limit` matches are found, so a specific query
    /// costs a page or two rather than the whole catalog. `maxPages` bounds a
    /// query that matches nothing.
    func searchSettingsCatalog(
        query: String?,
        platform: String? = nil,
        limit: Int = 25,
        maxPages: Int = 40
    ) async throws -> [SettingsCatalogDefinition] {
        guard let headers = await headers() else { return [] }

        var url = "\(betaUrl)/deviceManagement/configurationSettings?$top=\(pageSize(for: 999))"
        if let platform, !platform.isEmpty {
            let filter = "applicability/platform has '\(platform)'"
            url += "&$filter=\(filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter)"
        }

        var matches: [SettingsCatalogDefinition] = []
        var pages = 0

        while let currentUrl = URL(string: url), matches.count < limit, pages < maxPages {
            pages += 1
            let response: SettingsCatalogListResponse = try await fetch(
                url: currentUrl.absoluteString, headers: headers)

            for setting in response.value where setting.matches(query: query) {
                matches.append(setting)
                if matches.count >= limit { break }
            }

            if let nextLink = response.nextLink {
                url = nextLink
            } else {
                break
            }
        }

        return matches
    }
}
