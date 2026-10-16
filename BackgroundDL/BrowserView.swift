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
    @Published var isHome = true
    weak var webView: WKWebView?

    func goHome() {
        // Internal start page, not a third-party website; keep WebKit's cookie store.
        webView?.stopLoading()
        isHome = true
        address = ""
        loadURL = nil
        currentTitle = "主页"
        notice = ""
        webView?.loadHTMLString(
            "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><style>html,body{margin:0;height:100%;background:transparent}</style></head><body></body></html>",
            baseURL: nil
        )
    }

    func openSharedURL(_ url: URL) {
        isHome = false
        address = url.absoluteString
        loadURL = url
        webView?.load(URLRequest(url: url))
    }

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
        isHome = false
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
            isHome = false
            address = url.absoluteString
        }
    }
}

struct BrowserView: View {
    let sharedURL: URL?
    @StateObject private var state = BrowserState()
    @FocusState private var isEditingAddress: Bool
    @AppStorage("bgdl.webAppearanceMode") private var webAppearanceMode = "auto"

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
                BrowserWebView(state: state, appearanceMode: webAppearanceMode)
                if state.isHome {
                    ContentUnavailableView("浏览器主页", systemImage: "house",
                        description: Text("粘贴分享网址，在网页中点击下载。"))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 18) {
                Button { state.goHome() } label: { Image(systemName: "house") }
                    .accessibilityLabel("返回主页")
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
                    .frame(maxWidth: 96, alignment: .trailing)
                Menu {
                    Button {
                        webAppearanceMode = "auto"
                    } label: {
                        Label("智能深色（推荐）", systemImage: webAppearanceMode == "auto" ? "checkmark.circle.fill" : "moon.stars")
                    }
                    Button {
                        webAppearanceMode = "always"
                    } label: {
                        Label("始终深色", systemImage: webAppearanceMode == "always" ? "checkmark.circle.fill" : "moon.fill")
                    }
                    Button {
                        webAppearanceMode = "off"
                    } label: {
                        Label("网站原样", systemImage: webAppearanceMode == "off" ? "checkmark.circle.fill" : "sun.max")
                    }
                    Text("智能模式只在系统深色且网页背景偏亮时自动变暗；复杂网页可切回原样。")
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
        .onAppear {
            if let sharedURL { state.openSharedURL(sharedURL) }
        }
        .onChange(of: sharedURL) { _, url in
            if let url { state.openSharedURL(url) }
        }
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
    let appearanceMode: String
    @Environment(\.colorScheme) private var colorScheme

    // Inject at document start so sites with white backgrounds do not first paint an
    // entirely white screen. The filter darkens light pages; images and videos are
    // color-corrected separately. Avoid altering cookies or web navigation.
    private static let adaptiveDarkScript = #"""
    (() => {
      if (window.__bgdlThemeInstalled) return;
      window.__bgdlThemeInstalled = true;
      const styleID = 'bgdl-adaptive-dark-css';
      const style = document.createElement('style');
      style.id = styleID;
      style.textContent = `
        html.bgdl-adaptive-dark {
          filter: invert(1) hue-rotate(180deg) !important;
          background: #fff !important;
          color-scheme: light !important;
        }
        html.bgdl-adaptive-dark img,
        html.bgdl-adaptive-dark video,
        html.bgdl-adaptive-dark canvas,
        html.bgdl-adaptive-dark svg {
          filter: invert(1) hue-rotate(180deg) !important;
        }
      `;
      const attachStyle = () => {
        if (!style.isConnected && document.documentElement) {
          (document.head || document.documentElement).appendChild(style);
        }
      };
      let mode = 'auto';
      let systemDark = false;
      let pending = false;
      let observing = false;
      const brightness = (rgb) => {
        const m = rgb && rgb.match(/rgba?\((\d+)[, ]+(\d+)[, ]+(\d+)(?:[, /]+([\d.]+))?\)/i);
        if (!m) return null;
        if (m[4] !== undefined && Number(m[4]) < 0.15) return null;
        return 0.2126*Number(m[1]) + 0.7152*Number(m[2]) + 0.0722*Number(m[3]);
      };
      const effectiveBrightness = (node) => {
        let el = node;
        for (let n=0; el && n<12; n++,el=el.parentElement) {
          if (!el || !(el instanceof Element)) continue;
          const b = brightness(getComputedStyle(el).backgroundColor);
          if (b !== null) return b;
        }
        return 255;
      };
      const pageLooksBright = () => {
        if (!document.body) return false;
        // Undo our filter before measuring original styles; the filter doesn't
        // mutate computed background colors, but also avoid making the page dark
        // twice while inspecting single-page-app navigations.
        const w = Math.max(1, window.innerWidth), h = Math.max(1, window.innerHeight);
        const samplePoints = [
          [0.08,0.08],[0.50,0.08],[0.92,0.08],
          [0.08,0.40],[0.50,0.40],[0.92,0.40],
          [0.08,0.80],[0.50,0.80],[0.92,0.80]
        ];
        let bright=0, total=0;
        for (const [x,y] of samplePoints) {
          const el = document.elementFromPoint(Math.floor(w*x),Math.floor(h*y));
          if (!el) continue;
          total++;
          if (effectiveBrightness(el) >= 165) bright++;
        }
        const root = effectiveBrightness(document.body);
        return total > 0 ? bright >= Math.ceil(total * 0.55) : root >= 165;
      };
      const apply = () => {
        pending = false;
        attachStyle();
        const shouldDarken = mode === 'always' ||
          (mode === 'auto' && systemDark && pageLooksBright());
        if (document.documentElement) {
          document.documentElement.classList.toggle('bgdl-adaptive-dark',shouldDarken);
        }
      };
      const schedule = () => {
        if (pending) return;
        pending = true;
        setTimeout(apply, 80);
      };
      window.__bgdlSetTheme = (nextMode, dark) => {
        mode = nextMode === 'always' || nextMode === 'off' ? nextMode : 'auto';
        systemDark = !!dark;
        schedule();
      };
      document.addEventListener('DOMContentLoaded', () => {
        attachStyle(); schedule();
        if (!observing && document.documentElement) {
          observing = true;
          let mutationTimer = null;
          const observer = new MutationObserver(() => {
            if (!systemDark && mode !== 'always') return;
            if (mutationTimer) return;
            mutationTimer = setTimeout(() => { mutationTimer = null; schedule(); }, 1200);
          });
          observer.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['style','class']});
        }
      }, {once:true});
      window.addEventListener('pageshow', schedule);
      window.addEventListener('load', schedule);
      attachStyle();
    })();
    """#

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, appearanceMode: appearanceMode, systemDark: colorScheme == .dark)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let mode = ["auto", "always", "off"].contains(appearanceMode) ? appearanceMode : "auto"
        let initialTheme = "window.__bgdlSetTheme && window.__bgdlSetTheme('\(mode)', \(colorScheme == .dark ? "true" : "false"));"
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.adaptiveDarkScript + "\n" + initialTheme,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
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
        context.coordinator.appearanceMode = appearanceMode
        context.coordinator.systemDark = colorScheme == .dark
        context.coordinator.syncPageTheme(webView: browser)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: BrowserState
        var appearanceMode: String
        var systemDark: Bool
        private var lastAppearance = ""

        init(state: BrowserState, appearanceMode: String, systemDark: Bool) {
            self.state = state
            self.appearanceMode = appearanceMode
            self.systemDark = systemDark
        }

        func syncPageTheme(webView: WKWebView, force: Bool = false) {
            let signature = "\(appearanceMode)|\(systemDark)"
            if !force && lastAppearance == signature { return }
            lastAppearance = signature
            let mode = ["auto","always","off"].contains(appearanceMode) ? appearanceMode : "auto"
            let script = "window.__bgdlSetTheme && window.__bgdlSetTheme('\(mode)', \(systemDark ? "true" : "false"));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.updateNavigation(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.updateNavigation(webView)
            syncPageTheme(webView: webView, force: true)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            state.updateNavigation(webView)
            syncPageTheme(webView: webView, force: true)
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
