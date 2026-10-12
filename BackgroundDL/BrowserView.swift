import SwiftUI
import WebKit

@MainActor
final class BrowserState: ObservableObject {
    @Published var address = ""
    @Published var currentTitle = "浏览器"
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var message = ""
    @Published var showMessage = false
    @Published var notice = ""
    @Published var loadURL: URL?
    weak var webView: WKWebView?

    func open() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let normalized = input.contains("://") ? input : "https://" + input
        guard let url = URL(string: normalized),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            report("请输入有效的 HTTPS 网址。")
            return
        }
        loadURL = url
        webView?.load(URLRequest(url: url))
    }

    func report(_ text: String) {
        message = text
        showMessage = true
    }

    func updateNavigation(_ view: WKWebView) {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        isLoading = view.isLoading
        if let title = view.title, !title.isEmpty { currentTitle = title }
        if let url = view.url, url.scheme?.lowercased() == "https" {
            address = url.absoluteString
        }
    }
}

struct BrowserView: View {
    @StateObject private var state = BrowserState()
    @FocusState private var isEditingAddress: Bool
    @AppStorage("bgdl.forceDarkWebPages") private var forceDarkWebPages = false

    var body: some View {
        VStack(spacing: 0) {
            // One compact address row, rather than a redundant headline and instruction card.
            HStack(spacing: 9) {
                Image(systemName: "lock.shield")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("搜索或粘贴分享链接", text: $state.address)
                    .font(.subheadline)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isEditingAddress)
                    .submitLabel(.go)
                    .onSubmit(open)
                    .accessibilityIdentifier("browserAddress")
                if isEditingAddress && !state.address.isEmpty {
                    Button {
                        state.address = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("清空地址")
                }
                Button(action: open) {
                    Text("前往")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(state.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 15)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !state.notice.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.cyan)
                    Text(state.notice)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        state.notice = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("关闭提示")
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.thinMaterial)
            }

            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)

            // Let the actual website occupy almost all vertical space.
            ZStack {
                BrowserWebView(state: state, forceDarkWebPages: forceDarkWebPages)
                if state.webView?.url == nil && state.loadURL == nil {
                    ContentUnavailableView("打开网页", systemImage: "globe",
                        description: Text("粘贴分享网址，在网页中点击下载。"))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 24) {
                Button { state.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!state.canGoBack)
                    .accessibilityLabel("返回")
                Button { state.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!state.canGoForward)
                    .accessibilityLabel("前进")
                Button { state.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(state.webView?.url == nil)
                    .accessibilityLabel("刷新")
                Spacer(minLength: 8)
                if state.isLoading {
                    ProgressView().controlSize(.small)
                }
                Text(state.currentTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .trailing)
                Menu {
                    Toggle(isOn: $forceDarkWebPages) {
                        Label("深色模式下强制网页变暗", systemImage: "moon.stars")
                    }
                    Text("默认跟随网站和系统主题；若网页不支持深色，可手动开启。某些网站可能显示异常。")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("网页外观")
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .alert("网页提示", isPresented: $state.showMessage) {
            Button("确定", role: .cancel) { }
        } message: { Text(state.message) }
    }

    private func open() {
        isEditingAddress = false
        state.open()
    }
}

private struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var state: BrowserState
    let forceDarkWebPages: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, forceDarkPages: forceDarkWebPages, systemDark: colorScheme == .dark)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = context.coordinator
        browser.uiDelegate = context.coordinator
        browser.allowsBackForwardNavigationGestures = true
        browser.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        browser.isOpaque = false
        browser.backgroundColor = .systemBackground
        browser.underPageBackgroundColor = .systemBackground
        state.webView = browser
        if let url = state.loadURL { browser.load(URLRequest(url: url)) }
        return browser
    }

    func updateUIView(_ browser: WKWebView, context: Context) {
        browser.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        browser.underPageBackgroundColor = .systemBackground
        context.coordinator.forceDarkPages = forceDarkWebPages
        context.coordinator.systemDark = colorScheme == .dark
        context.coordinator.syncPageTheme(webView: browser)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: BrowserState
        var forceDarkPages: Bool
        var systemDark: Bool

        init(state: BrowserState, forceDarkPages: Bool, systemDark: Bool) {
            self.state = state
            self.forceDarkPages = forceDarkPages
            self.systemDark = systemDark
        }

        func syncPageTheme(webView: WKWebView) {
            // Websites implementing prefers-color-scheme are already handled by WebKit.
            // Optional CSS fallback is explicitly enabled by the user; do not invert images.
            let enabled = forceDarkPages && systemDark
            let script = #"""
            (() => {
              const id = 'bgdl-optional-dark-style';
              const old = document.getElementById(id);
              if (!\#(enabled ? "true" : "false")) { if (old) old.remove(); return; }
              if (old) return;
              const tag = document.createElement('style');
              tag.id = id;
              tag.textContent = `
                html { color-scheme: dark !important; background: #11151c !important; }
                body { background: #11151c !important; color: #e9edf3 !important; }
                input, textarea, select, button { color-scheme: dark !important; }
              `;
              (document.head || document.documentElement).appendChild(tag);
            })();
            """#
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.updateNavigation(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.updateNavigation(webView)
            syncPageTheme(webView: webView)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            state.updateNavigation(webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.updateNavigation(webView)
        }

        private func isExpectedNavigationCancellation(_ error: Error) -> Bool {
            let nsError = error as NSError
            return (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            state.updateNavigation(webView)
            guard !isExpectedNavigationCancellation(error) else { return }
            state.report("页面打开失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.cancel, preferences)
                capture(navigationAction.request, suggestedName: nil, browser: webView)
                return
            }
            decisionHandler(.allow, preferences)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let url = navigationResponse.response.url,
                  url.scheme?.lowercased() == "https" else {
                decisionHandler(.allow)
                return
            }
            let http = navigationResponse.response as? HTTPURLResponse
            let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
            let attachment = disposition.contains("attachment")
            if attachment || !navigationResponse.canShowMIMEType {
                decisionHandler(.cancel)
                capture(URLRequest(url: url), suggestedName: navigationResponse.response.suggestedFilename, browser: webView)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                if navigationAction.shouldPerformDownload {
                    capture(navigationAction.request, suggestedName: nil, browser: webView)
                } else {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        private func capture(_ original: URLRequest, suggestedName: String?, browser: WKWebView) {
            guard let url = original.url, url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
                state.report("该网页使用 blob:、data: 或其他临时下载协议，无法交给 iOS 后台下载。")
                return
            }
            guard (original.httpMethod ?? "GET").uppercased() == "GET" else {
                state.report("该下载请求使用表单 POST，不能安全地重新发起为后台 GET 下载。")
                return
            }
            let referer = browser.url
            Task { @MainActor in
                let cookies = await withCheckedContinuation { continuation in
                    browser.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        continuation.resume(returning: cookies)
                    }
                }
                let host = url.host?.lowercased() ?? ""
                let path = url.path.isEmpty ? "/" : url.path
                let matchingCookies = cookies.filter { cookie in
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let matchingHost = host == domain || host.hasSuffix("." + domain)
                    let matchingPath = path.hasPrefix(cookie.path)
                    let stillValid = cookie.expiresDate.map { $0 > Date() } ?? true
                    return matchingHost && matchingPath && stillValid && cookie.isSecure
                }
                var request = original
                request.timeoutInterval = 60
                if let cookieHeader = HTTPCookie.requestHeaderFields(with: matchingCookies)["Cookie"] {
                    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }
                if let userAgent = try? await browser.evaluateJavaScript("navigator.userAgent") as? String {
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                }
                if let referer, referer.scheme?.lowercased() == "https" {
                    if referer.host?.lowercased() == host {
                        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                    } else if let originHost = referer.host {
                        request.setValue("https://\(originHost)/", forHTTPHeaderField: "Referer")
                    }
                }
                let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                let fallback = last.isEmpty || last == "/" || last == "download" || last == "uc" ? "下载文件_\(UUID().uuidString.prefix(8))" : last
                let name = (suggestedName?.isEmpty == false && suggestedName != "download") ? suggestedName! : fallback
                BackgroundDownloader.shared.enqueue(request: request, originalURL: url.absoluteString, name: name, source: .browser)
                state.notice = "已接管：\(name)。切到“下载”页查看速度、预计完成时间与进度。"
            }
        }
    }
}
