import SwiftUI
import WebKit
import FleetMateCore

/// The public API has no definition-list operation. Read the signed-in web
/// client's picker; assignment itself always uses the documented API.
@MainActor
final class TicketWorkflowCatalog: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[TdxWorkflowChoice], Error>?
    private var timeout: Task<Void, Never>?
    private var pickerURL: URL?
    private var selector = "ddlWorkflow"
    private var choiceLabel = "workflows"

    func load(ticketId: Int, config: FleetMateConfig, taskTemplates: Bool = false) async throws -> [TdxWorkflowChoice] {
        selector = taskTemplates ? "ddlTaskTemplate" : "ddlWorkflow"
        choiceLabel = taskTemplates ? "task templates" : "workflows"
        let page = taskTemplates ? "/TicketAddTaskTemplate?" : "/TicketAssignWorkflow?"
        guard let url = URL(string: config.tdxTicketWebUrl(ticketId)
            .replacingOccurrences(of: "/TicketDet?", with: page)) else {
            throw TdxWorkflowError.actionFailed("The workflow picker address is unavailable.")
        }
        pickerURL = url
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .default()
                let view = WKWebView(frame: .zero, configuration: configuration)
                view.navigationDelegate = self
                webView = view
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(TdxWorkflowError.actionFailed("Couldn't load available \(self?.choiceLabel ?? "choices"). Refresh and try again.")))
                }
                view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, let expected = pickerURL,
              url.scheme == expected.scheme, url.host == expected.host, url.port == expected.port,
              url.path.caseInsensitiveCompare(expected.path) == .orderedSame,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter({ $0.name.lowercased() == "ticketid" })
                == URLComponents(url: expected, resolvingAgainstBaseURL: false)?.queryItems?.filter({ $0.name.lowercased() == "ticketid" }) else {
            // The shared web session may silently follow SSO redirects. Never
            // read a login page, and let the bounded timeout handle any page
            // that requires interaction.
            return
        }
        Task {
            do {
                let raw = try await webView.evaluateJavaScript("""
                (() => {
                    const select = document.querySelector('select#\(selector)');
                    if (!select || select.disabled) return null;
                    return Array.from(select.options).filter(o => !o.disabled && /^\\d+$/.test(o.value) && Number(o.value) > 0)
                        .map(o => ({id: Number(o.value), name: o.textContent.trim()}));
                })()
                """)
                guard let rows = raw as? [[String: Any]] else {
                    throw TdxWorkflowError.actionFailed("Available \(choiceLabel) couldn't be read. You may not have permission to assign workflows.")
                }
                let data = try JSONSerialization.data(withJSONObject: rows)
                let choices = try JSONDecoder().decode([TdxWorkflowChoice].self, from: data)
                var seen = Set<Int>()
                finish(.success(choices.filter { $0.id > 0 && !$0.name.isEmpty && seen.insert($0.id).inserted }))
            } catch { finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(TdxWorkflowError.actionFailed("Couldn't load available \(choiceLabel). Refresh and try again.")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(TdxWorkflowError.actionFailed("Couldn't load available \(choiceLabel). Refresh and try again.")))
    }

    private func finish(_ result: Result<[TdxWorkflowChoice], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }
}
