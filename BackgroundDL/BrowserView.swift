import SwiftUI
import WebKit

// 网页导航只是前台 UI；真正下载必须交给独立的后台 URLSession。
@MainActor
final class BrowserState: ObservableObject {
    @Published var address = ""
    @Published var currentTitle = "网页下载"
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
            report("请粘贴 HTTPS 分享链接；其他协议不受支持。")
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                TextField("粘贴别人的文件分享链接", text: $state.address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline)
                    .submitLabel(.go)
                    .focused($isEditingAddress)
                    .onSubmit(open)
                    .accessibilityIdentifier("browserAddress")
                Button("前往", action: open)
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)

            HStack(spacing: 20) {
                Button { state.webView?.goBack() } label: {
                    Image(systemName: "chevron.left")
                }.disabled(!state.canGoBack)
                Button { state.webView?.goForward() } label: {
                    Image(systemName: "chevron.right")
                }.disabled(!state.canGoForward)
                Button { state.webView?.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(state.webView?.url == nil)
                Spacer()
                if state.isLoading { ProgressView().controlSize(.small) }
                Text("网页点击下载 → 后台任务")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 10)

            if !state.notice.isEmpty {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(state.notice).lineLimit(2)
                    Spacer()
                    Button { state.notice = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
                .font(.caption)
                .padding(10)
                .background(Color.accentColor.opacity(0.10))
            }

            ZStack {
                BrowserWebView(state: state)
                if state.webView?.url == nil && state.loadURL == nil {
                    ContentUnavailableView("打开文件分享网页", systemImage: "globe",
                        description: Text("粘贴 Google Drive 或其他 HTTPS 分享链接，打开网页后直接点击网站的下载按钮。可接管的下载会自动进入下载列表。"))
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle("网页下载")
        .navigationBarTitleDisplayMode(.inline)
        .alert("下载提示", isPresented: $state.showMessage) {
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

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // 持久保存站点 Cookie；不读取 Safari 的 Cookie。
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = context.coordinator
        browser.uiDelegate = context.coordinator
        browser.allowsBackForwardNavigationGestures = true
        state.webView = browser
        if let url = state.loadURL { browser.load(URLRequest(url: url)) }
        return browser
    }

    func updateUIView(_ browser: WKWebView, context: Context) {
        // 不在这里根据 address 重新加载，否则每次重定向/状态刷新都可能重复下载。
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: BrowserState

        init(state: BrowserState) { self.state = state }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.updateNavigation(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.updateNavigation(webView)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            state.updateNavigation(webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.updateNavigation(webView)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            state.updateNavigation(webView)
            if (error as NSError).code != NSURLErrorCancelled {
                state.report("页面打开失败：\(error.localizedDescription)")
            }
        }

        // <a download>、WebKit 标记为下载的链接，由独立后台 URLSession 接管。
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

        // 服务器 Content-Disposition: attachment 或不可在页面展示的 MIME 类型。
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
                capture(URLRequest(url: url),
                        suggestedName: navigationResponse.response.suggestedFilename, browser: webView)
            } else {
                decisionHandler(.allow)
            }
        }

        // 网站 target=_blank / window.open 常用于真正的下载按钮。
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
            guard let url = original.url, url.scheme?.lowercased() == "https",
                  url.host != nil, url.user == nil, url.password == nil else {
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
                    // 只向相同站点提供完整来源 URL，避免将分享链接泄露到其他域名。
                    if referer.host?.lowercased() == host {
                        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                    } else if let originHost = referer.host {
                        request.setValue("https://\(originHost)/", forHTTPHeaderField: "Referer")
                    }
                }
                let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                let fallback = last.isEmpty || last == "/" || last == "download" || last == "uc"
                    ? "下载文件_\(UUID().uuidString.prefix(8))" : last
                let name = (suggestedName?.isEmpty == false && suggestedName != "download")
                    ? suggestedName! : fallback
                BackgroundDownloader.shared.enqueue(request: request, originalURL: url.absoluteString,
                                                     name: name, source: .browser)
                state.notice = "已接管：\(name)。切到「下载」查看进度。"
            }
        }
    }
}
