import SwiftUI
import WebKit
import UIKit
import UniformTypeIdentifiers

@main
struct LinkSwiftApp: App {
    @StateObject private var downloads = DownloadManager.shared
    var body: some Scene {
        WindowGroup {
            MainScreen().environmentObject(downloads)
        }
    }
}

struct CloudSite: Identifiable {
    let name: String
    let address: String
    var id: String { address }
    static let all: [CloudSite] = [
        .init(name: "百度网盘", address: "https://pan.baidu.com/disk/main"),
        .init(name: "阿里云盘", address: "https://www.alipan.com/drive"),
        .init(name: "中国移动云盘", address: "https://yun.139.com"),
        .init(name: "天翼云盘", address: "https://cloud.189.cn/web"),
        .init(name: "迅雷云盘", address: "https://pan.xunlei.com"),
        .init(name: "光鸭云盘", address: "https://www.guangyapan.com"),
        .init(name: "夸克网盘", address: "https://pan.quark.cn"),
        .init(name: "UC网盘", address: "https://drive.uc.cn"),
        .init(name: "123云盘", address: "https://www.123pan.com")
    ]
}

struct MainScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var browser = BrowserModel()
    @State private var selected = 0

    var body: some View {
        TabView(selection: $selected) {
            BrowserScreen(browser: browser)
                .tabItem { Label("网盘", systemImage: "cloud") }.tag(0)
            DownloadsScreen().tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .badge(downloads.activeCount).tag(1)
            NavigationStack {
                Form {
                    Section("LinkSwift iOS") {
                        LabeledContent("版本", value: "1.0.0")
                        LabeledContent("原脚本", value: browser.scriptLoaded ? "已打包" : "缺失")
                        Link("查看 LinkSwift 源码与开源许可", destination: URL(string: "https://github.com/hmjz100/LinkSwift")!)
                    }
                    Section("说明") {
                        Text("直链提取依赖网盘网页和 LinkSwift 原脚本。各网盘登录、请求头和下载有效期可能影响实际效果。")
                        Text("下载使用 iOS 原生后台 URLSession；未签名 IPA 需要自行签名。")
                    }
                }.navigationTitle("设置")
            }.tabItem { Label("设置", systemImage: "gearshape") }.tag(2)
        }
        .tint(.indigo)
        .onReceive(NotificationCenter.default.publisher(for: .linkSwiftGoDownloads)) { _ in
            selected = 1
        }
    }
}

extension Notification.Name {
    static let linkSwiftGoDownloads = Notification.Name("LinkSwiftGoDownloads")
}

struct BrowserScreen: View {
    @ObservedObject var browser: BrowserModel
    @State private var address = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "lock.shield")
                    TextField("输入网盘分享链接", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled().keyboardType(.URL)
                        .submitLabel(.go).onSubmit(open)
                    Button("前往", action: open)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(10)
                if browser.loading { ProgressView().progressViewStyle(.linear) }
                if !browser.scriptLoaded {
                    Text("脚本资源缺失，无法提取直链").foregroundStyle(.orange)
                        .font(.caption)
                }
                BrowserWebView(model: browser)
                HStack {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!browser.canGoBack)
                    Spacer()
                    Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!browser.canGoForward)
                    Spacer()
                    Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Spacer()
                    Button {
                        if let url = UIPasteboard.general.url { browser.navigate(url) }
                    } label: { Image(systemName: "doc.on.clipboard") }
                }
                .font(.title3).padding(.horizontal, 24).padding(.vertical, 12)
                .background(.regularMaterial)
            }
            .navigationTitle("LinkSwift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(CloudSite.all) { site in
                            Button(site.name) {
                                if let url = URL(string: site.address) { browser.navigate(url) }
                            }
                        }
                    } label: { Image(systemName: "square.grid.2x2") }
                }
            }
            .onAppear { address = browser.currentURL }
            .onChange(of: browser.currentURL) { address = $0 }
        }
    }
    private func open() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        if let url = URL(string: normalized) { browser.navigate(url) }
    }
}

struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var currentURL = CloudSite.all[0].address
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var scriptLoaded = false

    let webView: WKWebView
    private let session = URLSession(configuration: .default)
    private var requests: [String: URLSessionDataTask] = [:]

    override init() {
        let messages = WKUserContentController()
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()
        conf.userContentController = messages
        var loaded = false
        for name in ["bridge", "jquery.min", "sweetalert2.min", "md5.min", "resources", "linkswift"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Resources"),
               let code = try? String(contentsOf: url, encoding: .utf8) {
                let source = name == "bridge" ? code : "if (window.__LS_ALLOWED) {\n" + code + "\n}"
                messages.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                    forMainFrameOnly: true))
                if name == "linkswift" { loaded = code.contains("==UserScript==") }
            }
        }
        webView = WKWebView(frame: .zero, configuration: conf)
        super.init()
        scriptLoaded = loaded
        messages.add(self, name: "linkSwiftNative")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        if let url = URL(string: currentURL) { webView.load(URLRequest(url: url)) }
    }

    func navigate(_ url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        webView.load(URLRequest(url: url))
    }
    private func updateState() {
        currentURL = webView.url?.absoluteString ?? currentURL
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; updateState()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; updateState()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            navigate(url); decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { navigate(url) }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              Self.allowedHost(message.frameInfo.request.url?.host),
              let dict = message.body as? [String: Any],
              let action = dict["action"] as? String else { return }
        switch action {
        case "download":
            if let url = dict["url"] as? String {
                DownloadManager.shared.enqueue(url, name: dict["name"] as? String ?? "",
                    headers: dict["headers"] as? [String: String] ?? [:])
                NotificationCenter.default.post(name: .linkSwiftGoDownloads, object: nil)
            }
        case "clipboard":
            UIPasteboard.general.string = dict["text"] as? String
        case "open":
            if let raw = dict["url"] as? String, let url = URL(string: raw) { navigate(url) }
        case "request":
            startRequest(dict)
        case "abort":
            if let id = dict["id"] as? String { requests.removeValue(forKey: id)?.cancel() }
        default: break
        }
    }
    private static func allowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let exact = ["pan.baidu.com","yun.baidu.com","www.aliyundrive.com","www.alipan.com",
                     "yun.139.com","caiyun.139.com","cloud.189.cn","pan.xunlei.com",
                     "www.guangyapan.com","pan.quark.cn","drive.uc.cn"]
        return exact.contains(host) ||
            ["123pan.com","123pan.cn","123684.com","123865.com","123952.com","123912.com"]
                .contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }
    private func startRequest(_ options: [String: Any]) {
        guard let id = options["id"] as? String,
              let raw = options["url"] as? String, let url = URL(string: raw),
              url.scheme?.lowercased() == "https" else { return }
        var request = URLRequest(url: url)
        request.httpMethod = options["method"] as? String ?? "GET"
        if let h = options["headers"] as? [String: String] {
            for (k,v) in h where !["host","content-length"].contains(k.lowercased()) {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
        if let body = options["data"] as? String { request.httpBody = Data(body.utf8) }
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            let headers = http?.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") ?? ""
            let result: [String: Any] = [
                "status": http?.statusCode ?? 0,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                "responseHeaders": headers,
                "base64": (data ?? Data()).base64EncodedString(),
                "error": error?.localizedDescription ?? ""
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: result),
                  let payload = String(data: json, encoding: .utf8),
                  let quotedID = String(data: try! JSONSerialization.data(withJSONObject: [id]), encoding: .utf8) else { return }
            DispatchQueue.main.async {
                let js = "window.__LS_FINISH(\(quotedID.dropFirst().dropLast()),\(payload));"
                self?.webView.evaluateJavaScript(js, completionHandler: nil)
                self?.requests.removeValue(forKey: id)
            }
        }
        requests[id] = task
        task.resume()
    }
}

enum TaskState: String, Codable { case running, paused, finished, failed }
struct DownloadEntry: Identifiable, Codable {
    let id: String
    let url: String
    var name: String
    var state: TaskState
    var written: Int64
    var expected: Int64
    var localName: String?
    var completedAt: Date?
    var error: String?
    var headers: [String: String]
    var fraction: Double { expected > 0 ? min(1, Double(written)/Double(expected)) : 0 }
}

final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    @Published var items: [DownloadEntry] = []
    var activeCount: Int { items.filter { $0.state == .running }.count }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "io.linkswift.ios.background")
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private let key = "LinkSwiftDownloadEntries"
    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DownloadEntry].self, from: data) { items = decoded }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
    private var directory: URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    func localURL(_ item: DownloadEntry) -> URL? {
        guard let local = item.localName else { return nil }
        let file = directory.appendingPathComponent(local)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    func enqueue(_ raw: String, name: String, headers: [String: String] = [:]) {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return }
        let fallback = url.lastPathComponent.isEmpty ? "download.bin" : url.lastPathComponent
        let safe = (name.isEmpty ? fallback : name).replacingOccurrences(of: "/", with: "_")
        let entry = DownloadEntry(id: UUID().uuidString, url: raw, name: safe,
            state: .running, written: 0, expected: -1, localName: nil,
            completedAt: nil, error: nil, headers: headers)
        DispatchQueue.main.async {
            self.items.insert(entry, at: 0)
            self.save()
            self.launch(entry)
        }
    }
    private func launch(_ item: DownloadEntry, resume: Data? = nil) {
        let task: URLSessionDownloadTask
        if let resume {
            task = session.downloadTask(withResumeData: resume)
        } else {
            guard let url = URL(string: item.url) else { return }
            var request = URLRequest(url: url)
            for (k,v) in item.headers { request.setValue(v, forHTTPHeaderField: k) }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = item.id
        task.resume()
    }
    func pause(_ item: DownloadEntry) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].state = .paused; save()
        session.getAllTasks { tasks in
            (tasks.first { $0.taskDescription == item.id } as? URLSessionDownloadTask)?
                .cancel(byProducingResumeData: { data in
                    if let data { UserDefaults.standard.set(data, forKey: "resume:" + item.id) }
                })
        }
    }
    func resume(_ item: DownloadEntry) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].state = .running; items[i].error = nil; save()
        let data = UserDefaults.standard.data(forKey: "resume:" + item.id)
        UserDefaults.standard.removeObject(forKey: "resume:" + item.id)
        launch(items[i], resume: data)
    }
    func delete(_ offsets: IndexSet) {
        let removed = offsets.map { items[$0] }
        items.remove(atOffsets: offsets); save()
        session.getAllTasks { tasks in
            for item in removed { tasks.filter { $0.taskDescription == item.id }.forEach { $0.cancel() } }
        }
        for item in removed {
            if let url = localURL(item) { try? FileManager.default.removeItem(at: url) }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        DispatchQueue.main.async {
            guard let i = self.items.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }
            self.items[i].written = totalBytesWritten
            self.items[i].expected = totalBytesExpectedToWrite
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            DispatchQueue.main.async { self.fail(id, "HTTP \(status)，下载地址可能过期") }
            return
        }
        guard let item = items.first(where: { $0.id == id }) else { return }
        let ext = (item.name as NSString).pathExtension
        let stem = (item.name as NSString).deletingPathExtension
        var dest = directory.appendingPathComponent(item.name)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = directory.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async {
                if let i = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[i].state = .finished
                    self.items[i].name = dest.lastPathComponent
                    self.items[i].localName = dest.lastPathComponent
                    self.items[i].completedAt = Date()
                    self.items[i].written = self.items[i].expected > 0 ? self.items[i].expected : self.items[i].written
                    self.save()
                }
            }
        } catch {
            DispatchQueue.main.async { self.fail(id, error.localizedDescription) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        DispatchQueue.main.async {
            if self.items.first(where: { $0.id == id })?.state != .paused { self.fail(id, error.localizedDescription) }
        }
    }
    private func fail(_ id: String, _ reason: String) {
        guard let i = items.firstIndex(where: { $0.id == id && $0.state != .finished }) else { return }
        items[i].state = .failed; items[i].error = reason; save()
    }
}

struct DownloadsScreen: View {
    @EnvironmentObject private var store: DownloadManager
    @State private var add = false
    @State private var link = ""
    @State private var filename = ""
    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.doc",
                        description: Text("在网盘获取直链后点击“下载到 App”"))
                } else {
                    ForEach(store.items) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(item.name).font(.headline).lineLimit(2)
                                Spacer()
                                if item.state == .running {
                                    Button { store.pause(item) } label: { Image(systemName: "pause.circle") }
                                } else if item.state == .paused || item.state == .failed {
                                    Button { store.resume(item) } label: { Image(systemName: "play.circle") }
                                } else if let file = store.localURL(item) {
                                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                                }
                            }.buttonStyle(.borderless)
                            if item.state == .running { ProgressView(value: item.fraction) }
                            Text(item.state == .finished ? "完成：\(item.completedAt?.formatted() ?? "")" :
                                    item.state == .failed ? (item.error ?? "下载失败") :
                                    item.state == .paused ? "已暂停" : "下载中")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }.onDelete(perform: store.delete)
                }
            }
            .navigationTitle("下载管理")
            .toolbar {
                Button { add = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $add) {
                NavigationStack {
                    Form {
                        TextField("HTTPS 下载地址", text: $link).keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                        TextField("文件名（可选）", text: $filename)
                    }
                    .navigationTitle("新增下载")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("取消") { add = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("下载") {
                                store.enqueue(link, name: filename)
                                link = ""; filename = ""; add = false
                            }.disabled(URL(string: link)?.scheme != "https")
                        }
                    }
                }
            }
        }
    }
}
