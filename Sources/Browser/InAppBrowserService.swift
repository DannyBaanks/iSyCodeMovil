import Foundation
import WebKit
import UIKit

/// In-app WKWebView browser controllable by both the user and the agent (adapted from Palvia, MIT).
@MainActor
public final class InAppBrowserService: NSObject, ObservableObject {
    public static let shared = InAppBrowserService()

    public let webView: WKWebView
    @Published public private(set) var currentURL: URL?
    @Published public private(set) var pageTitle: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var estimatedProgress: Double = 0
    @Published public private(set) var isAgentControlled = false

    private var lockTimestamp: Date?
    private static let lockTimeout: TimeInterval = 120
    private var navigationContinuation: CheckedContinuation<Bool, Never>?
    private var kvoTokens: [NSKeyValueObservation] = []

    private override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        setupKVO()
    }

    private func setupKVO() {
        kvoTokens.append(webView.observe(\.isLoading) { [weak self] wv, _ in
            Task { @MainActor in self?.isLoading = wv.isLoading }
        })
        kvoTokens.append(webView.observe(\.canGoBack) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoBack = wv.canGoBack }
        })
        kvoTokens.append(webView.observe(\.canGoForward) { [weak self] wv, _ in
            Task { @MainActor in self?.canGoForward = wv.canGoForward }
        })
        kvoTokens.append(webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            Task { @MainActor in self?.estimatedProgress = wv.estimatedProgress }
        })
        kvoTokens.append(webView.observe(\.url) { [weak self] wv, _ in
            Task { @MainActor in self?.currentURL = wv.url }
        })
        kvoTokens.append(webView.observe(\.title) { [weak self] wv, _ in
            Task { @MainActor in self?.pageTitle = wv.title }
        })
    }

    public func markAgentActivity() {
        lockTimestamp = Date()
        isAgentControlled = true
    }

    public func releaseAgentControl() {
        lockTimestamp = nil
        isAgentControlled = false
    }

    private func checkLockTimeout() {
        if let ts = lockTimestamp, Date().timeIntervalSince(ts) > Self.lockTimeout {
            releaseAgentControl()
        }
    }

    public func closeAllPages() {
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        currentURL = nil
        pageTitle = nil
        releaseAgentControl()
    }

    @discardableResult
    public func navigate(to urlString: String, byAgent: Bool = false) async -> Result<String, InAppBrowserError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), url.scheme == "http" || url.scheme == "https" else {
            return .failure(.invalidURL(urlString))
        }
        if byAgent { markAgentActivity() }
        webView.load(URLRequest(url: url))
        let ok = await waitForNavigation(timeout: 30)
        return ok
            ? .success("Cargado \(webView.url?.absoluteString ?? candidate) — \(webView.title ?? "")")
            : .failure(.navigationTimeout)
    }

    public func goBack() async {
        guard webView.canGoBack else { return }
        webView.goBack()
        _ = await waitForNavigation(timeout: 15)
    }

    public func goForward() async {
        guard webView.canGoForward else { return }
        webView.goForward()
        _ = await waitForNavigation(timeout: 15)
    }

    public func reload() async {
        webView.reload()
        _ = await waitForNavigation(timeout: 15)
    }

    public func dismissKeyboard() {
        webView.resignFirstResponder()
        webView.endEditing(true)
        webView.evaluateJavaScript("document.activeElement && document.activeElement.blur()") { _, _ in }
    }

    public func getPageInfo(includeContent: Bool = true) async -> Result<String, InAppBrowserError> {
        checkLockTimeout()
        let url = webView.url?.absoluteString ?? "(sin página)"
        let title = webView.title ?? "(sin título)"
        var info = "URL: \(url)\nTítulo: \(title)"
        if includeContent {
            switch await executeJavaScript(Self.simplifiedDOMScript) {
            case .success(let dom):
                let clipped = dom.count > 12_000 ? String(dom.prefix(12_000)) + "\n...(recortado)" : dom
                info += "\n\nContenido:\n\(clipped)"
            case .failure(let err):
                info += "\n\n[No se pudo leer el contenido: \(err.localizedDescription)]"
            }
        }
        return .success(info)
    }

    public func click(elementId: String? = nil, selector: String? = nil) async -> Result<String, InAppBrowserError> {
        markAgentActivity()
        guard let target = resolveTarget(elementId: elementId, selector: selector) else {
            return .failure(.elementNotFound("Indica element_id o selector."))
        }
        let script = """
        (function() {
            const el = \(target);
            if (!el) return JSON.stringify({error: 'Elemento no encontrado'});
            el.click();
            if (document.activeElement) document.activeElement.blur();
            return JSON.stringify({ok: true, tag: el.tagName, text: (el.textContent || '').trim().substring(0, 80)});
        })()
        """
        return parseJSResult(await executeJavaScript(script), action: "click")
    }

    public func input(elementId: String? = nil, selector: String? = nil, text: String) async -> Result<String, InAppBrowserError> {
        markAgentActivity()
        guard let target = resolveTarget(elementId: elementId, selector: selector) else {
            return .failure(.elementNotFound("Indica element_id o selector."))
        }
        let escaped = jsEscape(text)
        let script = """
        (function() {
            const el = \(target);
            if (!el) return JSON.stringify({error: 'Elemento no encontrado'});
            el.focus();
            const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
            if (setter) { setter.call(el, \(escaped)); } else { el.value = \(escaped); }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.blur();
            return JSON.stringify({ok: true, tag: el.tagName, value: (el.value || '').substring(0, 80)});
        })()
        """
        let res = await executeJavaScript(script)
        dismissKeyboard()
        return parseJSResult(res, action: "input")
    }

    public func scroll(direction: String = "down", pixels: Int = 500) async -> Result<String, InAppBrowserError> {
        markAgentActivity()
        let y = direction.lowercased() == "up" ? -abs(pixels) : abs(pixels)
        let script = "window.scrollBy(0, \(y)); JSON.stringify({scrollY: window.scrollY, scrollHeight: document.body.scrollHeight})"
        return await executeJavaScript(script)
    }

    // MARK: - Helpers

    private func waitForNavigation(timeout: TimeInterval) async -> Bool {
        if let existing = navigationContinuation {
            navigationContinuation = nil
            existing.resume(returning: false)
        }
        return await withCheckedContinuation { continuation in
            navigationContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let pending = self?.navigationContinuation {
                    self?.navigationContinuation = nil
                    pending.resume(returning: false)
                }
            }
        }
    }

    private func completeNavigation(success: Bool) {
        guard let pending = navigationContinuation else { return }
        navigationContinuation = nil
        pending.resume(returning: success)
    }

    private static let jsErrorPrefix = "__ISY_JS_ERR__:"

    private func executeJavaScript(_ script: String) async -> Result<String, InAppBrowserError> {
        let safe = "try { \(script) } catch(__e) { '\(Self.jsErrorPrefix)' + String(__e) }"
        do {
            let result = try await webView.evaluateJavaScript(safe)
            let str = result.map { String(describing: $0) } ?? "(undefined)"
            if str.hasPrefix(Self.jsErrorPrefix) {
                return .failure(.javaScriptError(String(str.dropFirst(Self.jsErrorPrefix.count))))
            }
            return .success(str)
        } catch {
            return .failure(.javaScriptError(error.localizedDescription))
        }
    }

    private func parseJSResult(_ result: Result<String, InAppBrowserError>, action: String) -> Result<String, InAppBrowserError> {
        switch result {
        case .success(let json):
            if let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = dict["error"] as? String {
                return .failure(.elementNotFound(err))
            }
            return .success("\(action): \(json)")
        case .failure(let err):
            return .failure(err)
        }
    }

    private func resolveTarget(elementId: String?, selector: String?) -> String? {
        if let eid = elementId, !eid.isEmpty {
            return "document.querySelector('[data-isy-id=' + \(jsEscape(eid)) + ']')"
        }
        if let sel = selector, !sel.isEmpty {
            return "document.querySelector(\(jsEscape(sel)))"
        }
        return nil
    }

    private func jsEscape(_ str: String) -> String {
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }

    private static let simplifiedDOMScript = """
    (function() {
        var _ids = new Set();
        var _chars = 'abcdefghijkmnpqrstuvwxyz23456789';
        function genId() {
            var id;
            do { id = ''; for (var i = 0; i < 5; i++) id += _chars[Math.floor(Math.random()*_chars.length)]; } while (_ids.has(id));
            _ids.add(id);
            return id;
        }
        function tagEl(node) {
            var id = genId();
            node.setAttribute('data-isy-id', id);
            return id;
        }
        document.querySelectorAll('[data-isy-id]').forEach(function(el) { el.removeAttribute('data-isy-id'); });
        function walk(node, depth) {
            if (depth > 14) return '';
            var skip = new Set(['SCRIPT','STYLE','NOSCRIPT','SVG','PATH','META','LINK']);
            if (skip.has(node.tagName)) return '';
            var out = '';
            var tag = (node.tagName || '').toLowerCase();
            if (tag === 'a') {
                var id = tagEl(node);
                var text = (node.innerText || '').trim().substring(0, 80);
                if (text) out += '[#' + id + ' link: ' + text + '] ';
            } else if (tag === 'input' || tag === 'textarea') {
                var id = tagEl(node);
                var p = node.placeholder || node.name || '';
                out += '[#' + id + ' ' + tag + ' placeholder="' + p.substring(0, 40) + '" value="' + (node.value || '').substring(0, 40) + '"] ';
            } else if (tag === 'button') {
                var id = tagEl(node);
                out += '[#' + id + ' button: ' + (node.innerText || node.value || '').trim().substring(0, 50) + '] ';
            } else if (node.nodeType === 3) {
                var t = node.textContent.trim();
                if (t.length > 0) out += t + ' ';
            }
            if (node.childNodes) {
                for (var c of node.childNodes) { out += walk(c, depth + 1); }
            }
            if (['P','DIV','LI','TR','H1','H2','H3','H4','BR','SECTION','ARTICLE'].includes(node.tagName)) {
                out += '\\n';
            }
            return out;
        }
        return walk(document.body || document.documentElement, 0).replace(/\\n{3,}/g, '\\n\\n').trim();
    })()
    """
}

extension InAppBrowserService: WKNavigationDelegate {
    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in completeNavigation(success: true) }
    }
    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in completeNavigation(success: false) }
    }
    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in completeNavigation(success: false) }
    }
}

public enum InAppBrowserError: LocalizedError {
    case invalidURL(String)
    case navigationTimeout
    case javaScriptError(String)
    case elementNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "URL no válida: \(url)"
        case .navigationTimeout: return "La página tardó demasiado en cargar."
        case .javaScriptError(let msg): return "Error de script: \(msg)"
        case .elementNotFound(let msg): return msg
        }
    }
}
