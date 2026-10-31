import SwiftUI
import WebKit
import UniformTypeIdentifiers

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
        webView?.stopLoading()
        isHome = true
        address = ""
        loadURL = nil
        currentTitle = "主页"
        notice = ""
        webView?.loadHTMLString("<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body></body></html>", baseURL: nil)
    }

    func loadSharedURL(_ url: URL) {
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
    @ObservedObject var state: BrowserState
    let sharedURL: URL?
    let openDownloads: () -> Void
    let openSettings: () -> Void
    let onScrollHideChange: (Bool) -> Void
    let incomingLinkRevision: UUID
    let acceptDroppedProviders: ([NSItemProvider]) -> Bool
    @FocusState private var isEditingAddress: Bool
    @AppStorage("bgdl.webAppearanceMode") private var webAppearanceMode = "auto"
    @ObservedObject private var library = BrowserLibrary.shared
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            if !state.notice.isEmpty { noticeCard }
            ZStack {
                BrowserWebView(state: state, appearanceMode: webAppearanceMode,
                           onScrollHideChange: onScrollHideChange)
                if state.isHome {
                    BrowserStartPage(open: { url in
                        state.loadSharedURL(url)
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [UTType.url, UTType.fileURL, UTType.plainText], isTargeted: nil) {
                acceptDroppedProviders($0)
            }
        }
        .background(AppTheme.pageBackground)
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            if let sharedURL { state.loadSharedURL(sharedURL) }
        }
        .onChange(of: incomingLinkRevision) { _, _ in
            if let sharedURL { state.loadSharedURL(sharedURL) }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                BrowserHistoryView(open: { url in
                    showHistory = false
                    state.loadSharedURL(url)
                })
            }
        }
        .alert("网页提示", isPresented: $state.showMessage) {
            Button("确定", role: .cancel) { }
        } message: { Text(state.message) }
    }

    private var addressBar: some View {
        HStack(spacing: 9) {
            Image(systemName: state.isHome ? "globe" : "lock.shield.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(state.isHome ? Color.secondary : AppTheme.accent)
            TextField("搜索或粘贴链接", text: $state.address)
                .font(.subheadline)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isEditingAddress)
                .submitLabel(.go)
                .onSubmit(open)
                .accessibilityIdentifier("browserAddress")
            if state.isLoading {
                ProgressView().controlSize(.small)
            }
            if isEditingAddress && !state.address.isEmpty {
                Button {
                    state.address = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("清空地址")
            }
            if !state.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: open) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.accent)
                }
                .accessibilityLabel("前往")
            }
            Menu {
                if let url = state.webView?.url, url.scheme == "https" {
                    Button {
                        library.toggleBookmark(url: url, title: state.currentTitle)
                    } label: {
                        Label(library.isBookmarked(url) ? "取消收藏此网页" : "收藏此网页",
                              systemImage: library.isBookmarked(url) ? "star.slash" : "star")
                    }
                }
                Button { showHistory = true } label: {
                    Label("浏览历史", systemImage: "clock.arrow.circlepath")
                }
                Button { openDownloads() } label: {
                    Label("下载列表", systemImage: "arrow.down.circle")
                }
                Button { openSettings() } label: {
                    Label("设置", systemImage: "gearshape")
                }
                Divider()
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
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("网页菜单")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(AppTheme.border)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var noticeCard: some View {
        HStack(spacing: 10) {
            Button {
                state.notice = ""
                openDownloads()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(AppTheme.accent)
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.notice)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("点击查看下载进度")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看已接管的下载任务")
            .accessibilityIdentifier("capturedDownloadNotice")
            Button {
                state.notice = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.border)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func open() {
        isEditingAddress = false
        state.open()
    }
}

private struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var state: BrowserState
    let appearanceMode: String
    let onScrollHideChange: (Bool) -> Void
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
        Coordinator(state: state, appearanceMode: appearanceMode,
                    systemDark: colorScheme == .dark, onScrollHideChange: onScrollHideChange)
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
        browser.scrollView.contentInsetAdjustmentBehavior = .never
        browser.backgroundColor = .systemBackground
        browser.underPageBackgroundColor = .systemBackground
        state.webView = browser
        context.coordinator.observe(browser.scrollView)
        if let url = state.loadURL { browser.load(URLRequest(url: url)) }
        return browser
    }

    func updateUIView(_ browser: WKWebView, context: Context) {
        browser.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        browser.underPageBackgroundColor = .systemBackground
        context.coordinator.appearanceMode = appearanceMode
        context.coordinator.systemDark = colorScheme == .dark
        context.coordinator.onScrollHideChange = onScrollHideChange
        context.coordinator.syncPageTheme(webView: browser)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: BrowserState
        var appearanceMode: String
        var systemDark: Bool
        var onScrollHideChange: (Bool) -> Void
        private var lastAppearance = ""
        private var scrollObservation: NSKeyValueObservation?
        private var lastOffsetY: CGFloat = 0
        private var travel: CGFloat = 0
        private var lastDirection: Int = 0

        init(state: BrowserState, appearanceMode: String, systemDark: Bool,
             onScrollHideChange: @escaping (Bool) -> Void) {
            self.state = state
            self.appearanceMode = appearanceMode
            self.systemDark = systemDark
            self.onScrollHideChange = onScrollHideChange
        }

        func observe(_ scrollView: UIScrollView) {
            lastOffsetY = scrollView.contentOffset.y
            scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                let y = scroll.contentOffset.y
                DispatchQueue.main.async {
                    guard let self else { return }
                    let delta = y - self.lastOffsetY
                    self.lastOffsetY = y
                    if y <= 6 {
                        self.travel = 0
                        self.lastDirection = 0
                        self.onScrollHideChange(false)
                        return
                    }
                    guard abs(delta) > 0.5 else { return }
                    let direction = delta > 0 ? 1 : -1
                    if direction != self.lastDirection {
                        self.travel = 0
                        self.lastDirection = direction
                    }
                    self.travel += abs(delta)
                    if self.travel >= 28 {
                        self.travel = 0
                        self.onScrollHideChange(direction > 0)
                    }
                }
            }
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
            if let url = webView.url, url.scheme?.lowercased() == "https" {
                BrowserLibrary.shared.record(url: url, title: webView.title ?? url.host ?? "网页")
            }
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
                DownloadCoordinator.shared.enqueue(request: request, originalURL: url.absoluteString, name: name, source: .browser)
                state.notice = "已接管：\(name)"
            }
        }
    }
}


// Browser history and bookmarks contain only user-visited HTTPS pages; cookies,
// credentials and page contents are never written here.
struct BrowserEntry: Codable, Identifiable {
    let url: String
    var title: String
    var visited: Date
    var id: String { url }
}

@MainActor
final class BrowserLibrary: ObservableObject {
    static let shared = BrowserLibrary()
    @Published private(set) var bookmarks: [BrowserEntry] = []
    @Published private(set) var history: [BrowserEntry] = []
    private let bookmarkKey = "bgdl.browser.bookmarks.v2"
    private let historyKey = "bgdl.browser.history.v2"
    private init() {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            bookmarks = (try? JSONDecoder().decode([BrowserEntry].self, from: data)) ?? []
        }
        if let data = UserDefaults.standard.data(forKey: historyKey) {
            history = (try? JSONDecoder().decode([BrowserEntry].self, from: data)) ?? []
        }
    }
    func isBookmarked(_ url: URL) -> Bool { bookmarks.contains { $0.url == url.absoluteString } }
    func toggleBookmark(url: URL, title: String) {
        guard url.scheme?.lowercased() == "https" else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(BrowserEntry(url: url.absoluteString, title: title,
                                         visited: Date()), at: 0)
        }
        save(bookmarks, as: bookmarkKey)
    }
    func record(url: URL, title: String) {
        guard url.scheme?.lowercased() == "https" else { return }
        history.removeAll { $0.url == url.absoluteString }
        history.insert(BrowserEntry(url: url.absoluteString, title: title, visited: Date()), at: 0)
        if history.count > 150 { history.removeLast(history.count - 150) }
        save(history, as: historyKey)
    }
    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
    func deleteHistory(_ url: String) {
        history.removeAll { $0.url == url }
        save(history, as: historyKey)
    }
    private func save(_ entries: [BrowserEntry], as key: String) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private struct BrowserStartPage: View {
    @ObservedObject private var library = BrowserLibrary.shared
    let open: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if !library.bookmarks.isEmpty { bookmarks }
                if !library.history.isEmpty { recent }
                if library.history.isEmpty && library.bookmarks.isEmpty { empty }
            }
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.top, 18)
            .padding(.bottom, 96)
        }
        .background(AppTheme.pageBackground)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text("把链接变成下载")
                .font(.title2.bold())
            Text("粘贴、拖入或分享链接，网页里的文件会交给后台下载。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.64, blue: 0.80), Color(red: 0.07, green: 0.42, blue: 0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }

    private var bookmarks: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("收藏", icon: "star.fill")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(library.bookmarks.prefix(9)) { entry in
                    Button {
                        if let url = URL(string: entry.url) { open(url) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(initial(entry))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 34, height: 34)
                                .background(AppTheme.accent.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayTitle(entry))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(host(entry))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(AppTheme.border)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("最近访问", icon: "clock.fill")
            VStack(spacing: 0) {
                ForEach(library.history.prefix(8)) { entry in
                    Button {
                        if let url = URL(string: entry.url) { open(url) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.05), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayTitle(entry))
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(host(entry))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    if entry.id != library.history.prefix(8).last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AppTheme.border)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("收藏和最近访问会显示在这里")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
    }

    private func host(_ entry: BrowserEntry) -> String {
        URL(string: entry.url)?.host ?? entry.url
    }

    private func displayTitle(_ entry: BrowserEntry) -> String {
        entry.title.isEmpty ? host(entry) : entry.title
    }

    private func initial(_ entry: BrowserEntry) -> String {
        String(host(entry).replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased()
    }
}

private struct BrowserHistoryView: View {
    @ObservedObject private var library = BrowserLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirmingClear = false
    let open: (URL) -> Void

    private struct SectionGroup: Identifiable {
        let id: String
        let entries: [BrowserEntry]
    }

    private var results: [BrowserEntry] {
        library.history.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                $0.url.localizedCaseInsensitiveContains(search)
        }
    }

    private var sections: [SectionGroup] {
        var today: [BrowserEntry] = []
        var yesterday: [BrowserEntry] = []
        var earlier: [BrowserEntry] = []
        for entry in results {
            if Calendar.current.isDateInToday(entry.visited) { today.append(entry) }
            else if Calendar.current.isDateInYesterday(entry.visited) { yesterday.append(entry) }
            else { earlier.append(entry) }
        }
        return [
            SectionGroup(id: "今天", entries: today),
            SectionGroup(id: "昨天", entries: yesterday),
            SectionGroup(id: "更早", entries: earlier)
        ].filter { !$0.entries.isEmpty }
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.id) {
                    ForEach(section.entries) { entry in
                        Button {
                            if let url = URL(string: entry.url) { open(url) }
                        } label: {
                            HStack(spacing: 12) {
                                Text(initial(entry))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 34, height: 34)
                                    .background(AppTheme.accent.opacity(0.12), in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(entry))
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text("\(host(entry)) · \(time(entry))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                library.deleteHistory(entry.url)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("移除这条历史", systemImage: "trash") {
                                library.deleteHistory(entry.url)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("浏览历史")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "查找历史记录")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("清除", role: .destructive) { confirmingClear = true }
                    .disabled(library.history.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .confirmationDialog("清除全部历史？", isPresented: $confirmingClear) {
            Button("清除历史", role: .destructive) { library.clearHistory() }
        } message: {
            Text("不会删除 Cookie、收藏或下载文件。")
        }
    }

    private func host(_ entry: BrowserEntry) -> String {
        URL(string: entry.url)?.host ?? entry.url
    }

    private func title(_ entry: BrowserEntry) -> String {
        entry.title.isEmpty ? host(entry) : entry.title
    }

    private func initial(_ entry: BrowserEntry) -> String {
        String(host(entry).replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased()
    }

    private func time(_ entry: BrowserEntry) -> String {
        entry.visited.formatted(date: .omitted, time: .shortened)
    }
}
