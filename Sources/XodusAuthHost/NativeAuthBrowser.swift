// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import WebKit

struct BrowserTrust {
    let navigation: (URL) -> Bool
    let bridge: (URL) -> Bool
    let finish: (URL) -> Bool
}

enum NativePopupDisposition: Equatable {
    case sameView, placeholder, blocked
}

@MainActor
final class NativeAuthBrowser: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let view: WKWebView
    private let trust: BrowserTrust
    private let received: (LegacyDA) -> Void
    private let failed: (HostFailure) -> Void
    private var generation = 0
    private var controlGeneration: UInt64 = 0
    private var terminal = false
    private var delivered = false
    private var validatingDA = false
    private var acceptsMessages = false
    private var activeNavigation: WKNavigation?
    private var superseded: [ObjectIdentifier: WKNavigation] = [:]

    init(trust: BrowserTrust, received: @escaping (LegacyDA) -> Void,
         failed: @escaping (HostFailure) -> Void) {
        self.trust = trust
        self.received = received
        self.failed = failed
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: LegacyBridge.handler)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isInspectable = false
    }

    func load(_ request: URLRequest, userAgent: String?) throws {
        guard !terminal, let url = request.url, trust.navigation(url) else {
            throw HostFailure.navigationFailed
        }
        if let navigation = activeNavigation { try supersede(navigation) }
        prepareDocument(userAgent: userAgent)
        activeNavigation = view.load(request)
        guard activeNavigation != nil else { throw HostFailure.navigationFailed }
    }

    private func prepareDocument(userAgent: String?) {
        generation += 1
        controlGeneration += 1
        delivered = false
        validatingDA = false
        acceptsMessages = false
        view.configuration.userContentController.removeAllUserScripts()
        view.configuration.userContentController.addUserScript(WKUserScript(
            source: LegacyBridge.injection(navigation: controlGeneration),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view.customUserAgent = userAgent
    }

    func loadSyntheticDocument(_ html: String, baseURL: URL) throws {
        guard baseURL.host == "auth-host-fixture.invalid", trust.navigation(baseURL), !terminal else {
            throw HostFailure.navigationFailed
        }
        if let navigation = activeNavigation { try supersede(navigation) }
        prepareDocument(userAgent: nil)
        activeNavigation = view.loadHTMLString(html, baseURL: baseURL)
        guard activeNavigation != nil else { throw HostFailure.navigationFailed }
    }

    private func supersede(_ navigation: WKNavigation) throws {
        guard superseded.count < 256 else { throw HostFailure.navigationFailed }
        superseded[ObjectIdentifier(navigation)] = navigation
    }

    func close() {
        guard !terminal else { return }
        terminal = true
        generation += 1
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: LegacyBridge.handler)
        view.configuration.userContentController.removeAllUserScripts()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    private func fail(_ failure: HostFailure) {
        guard !terminal else { return }
        close()
        failed(failure)
    }

    private func trustedMessage(_ message: WKScriptMessage) -> Bool {
        guard !terminal, message.name == LegacyBridge.handler, message.webView === view,
              message.frameInfo.isMainFrame, let url = message.frameInfo.request.url,
              let current = view.url, trust.bridge(url), trust.bridge(current),
              Self.origin(url) == Self.origin(current) else { return false }
        let origin = message.frameInfo.securityOrigin
        return origin.protocol.lowercased() == "https"
            && origin.host.lowercased() == url.host?.lowercased()
            && (origin.port == 0 || origin.port == 443)
    }

    static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? 443)"
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard !terminal, acceptsMessages else { return }
        guard trustedMessage(message) else { return }
        do {
            guard let text = message.body as? String else { throw HostFailure.bridgeInvalid }
            let wrapper = try PrivateJSON.parse(Data(text.utf8)).object(keys: ["navigation", "document", "message"])
            guard let document = wrapper["document"]?.string, UUID(uuidString: document) != nil,
                  wrapper["navigation"]?.unsigned == controlGeneration,
                  let raw = wrapper["message"]?.string else { throw HostFailure.bridgeInvalid }
            let notification = try LegacyNotification(raw: raw)
            let expectedGeneration = generation
            switch notification {
            case .ignored: return
            case .context(let context):
                let callback = try LegacyBridge.callback(context: context)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let accepted = try await self.view.callAsyncJavaScript(LegacyBridge.dispatch,
                            arguments: ["document": document, "callback": callback], in: nil, contentWorld: .page)
                        guard !self.terminal, self.generation == expectedGeneration else { return }
                        guard accepted as? Bool == true else { throw HostFailure.javaScriptFailed }
                    } catch {
                        guard !self.terminal, self.generation == expectedGeneration else { return }
                        self.fail(.javaScriptFailed)
                    }
                }
            case .da(let data):
                guard !delivered, !validatingDA else { throw HostFailure.bridgeInvalid }
                validatingDA = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let accepted = try await self.view.callAsyncJavaScript(LegacyBridge.validateDocument,
                            arguments: ["document": document], in: nil, contentWorld: .page)
                        guard !self.terminal, self.generation == expectedGeneration else { return }
                        self.validatingDA = false
                        guard accepted as? Bool == true else { throw HostFailure.bridgeInvalid }
                        self.deliver(data)
                    } catch {
                        guard !self.terminal, self.generation == expectedGeneration else { return }
                        self.fail(.bridgeInvalid)
                    }
                }
            }
        } catch { fail(.bridgeInvalid) }
    }

    private func deliver(_ data: LegacyDA) {
        guard !terminal, !delivered else { fail(.bridgeInvalid); return }
        delivered = true
        received(data)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard webView === view else { decisionHandler(.cancel); return }
        decisionHandler(navigationPolicy(for: navigationAction.request,
                                         isMainFrame: navigationAction.targetFrame?.isMainFrame))
    }

    func navigationPolicy(for request: URLRequest, isMainFrame: Bool?) -> WKNavigationActionPolicy {
        guard !terminal else { return .cancel }
        if isMainFrame == false { return .allow }
        if isMainFrame == nil {
            return popupDisposition(for: request) == .blocked ? .cancel : .allow
        }
        return request.url.map(trust.navigation) == true ? .allow : .cancel
    }

    func popupDisposition(for request: URLRequest) -> NativePopupDisposition {
        guard !terminal, let url = request.url else { return .blocked }
        if url.absoluteString == "about:blank" { return .placeholder }
        return trust.navigation(url) ? .sameView : .blocked
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !terminal, let navigation else { return }
        if let activeNavigation, activeNavigation !== navigation {
            do { try supersede(activeNavigation) }
            catch { fail(.navigationFailed); return }
        }
        activeNavigation = navigation
        generation += 1
        validatingDA = false
        acceptsMessages = false
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !terminal, let navigation, navigation === activeNavigation else { return }
        acceptsMessages = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !terminal, let navigation else { return }
        superseded.removeValue(forKey: ObjectIdentifier(navigation))
        guard navigation === activeNavigation, let url = view.url, trust.navigation(url) else { return }
        let expectedGeneration = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let verified = try await self.view.callAsyncJavaScript(LegacyBridge.verifyBridge,
                    arguments: [:], in: nil, contentWorld: .page)
                guard !self.terminal, self.generation == expectedGeneration else { return }
                guard verified as? Bool == true else { throw HostFailure.javaScriptFailed }
                guard self.trust.finish(url), !self.delivered, !self.validatingDA else { return }
                self.validatingDA = true
                let value = try await self.view.callAsyncJavaScript(LegacyBridge.extract,
                    arguments: [:], in: nil, contentWorld: .page)
                guard !self.terminal, self.generation == expectedGeneration else { return }
                self.validatingDA = false
                guard let json = value as? String, let current = self.view.url,
                      self.trust.finish(current) else { throw HostFailure.javaScriptFailed }
                self.deliver(try LegacyDA(PrivateJSON.parse(Data(json.utf8))))
            } catch {
                guard !self.terminal, self.generation == expectedGeneration else { return }
                self.fail(.javaScriptFailed)
            }
        }
    }

    private func navigationFailure(_ navigation: WKNavigation?, _ error: Error, provisional: Bool) {
        if let navigation { superseded.removeValue(forKey: ObjectIdentifier(navigation)) }
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if provisional && error.domain == "WebKitErrorDomain" && error.code == 102 { return }
        fail(.navigationFailed)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailure(navigation, error, provisional: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationFailure(navigation, error, provisional: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(.rendererTerminated) }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === view else { fail(.bridgeInvalid); return }
        fail(.cancelled)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === view else { return nil }
        handlePopup(navigationAction.request)
        return nil
    }

    func handlePopup(_ request: URLRequest) {
        switch popupDisposition(for: request) {
        case .blocked, .placeholder: return
        case .sameView:
            do {
                if let navigation = activeNavigation { try supersede(navigation) }
                activeNavigation = view.load(request)
                guard activeNavigation != nil else { throw HostFailure.navigationFailed }
            }
            catch { fail(.navigationFailed) }
        }
    }
}
