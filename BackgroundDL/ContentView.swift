import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack { BrowserView() }
                .tabItem { Label("浏览器", systemImage: "safari") }
            NavigationStack { DownloadListView() }
                .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
        }
        .tint(.cyan)
    }
}

private struct DownloadListView: View {
    @ObservedObject private var store = DownloadStore.shared
    @State private var link = ""
    @State private var isPreparing = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [.blue.opacity(0.10), .cyan.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("备用直链")
                            .font(.headline)
                        TextField("备用：粘贴 HTTPS 直链", text: $link, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .lineLimit(2...4)
                        Button {
                            Task { await addDownload() }
                        } label: {
                            HStack {
                                Label("开始后台下载", systemImage: "arrow.down.circle.fill")
                                Spacer()
                                if isPreparing { ProgressView() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPreparing || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("优先用“浏览器”：打开任意 HTTPS 分享网页，再点击网站自己的下载按钮。")
                }

                Section {
                    if store.items.isEmpty {
                        ContentUnavailableView("暂无下载任务", systemImage: "square.and.arrow.down",
                                               description: Text("去“浏览器”打开分享链接，点网页下载。"))
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(store.items) { item in
                        DownloadRow(item: item,
                                    fileURL: store.fileURL(for: item),
                                    pause: { BackgroundDownloader.shared.changeState(id: item.id, action: .pause) },
                                    resume: { BackgroundDownloader.shared.changeState(id: item.id, action: .resume) },
                                    cancel: { BackgroundDownloader.shared.changeState(id: item.id, action: .cancel) },
                                    retry: { Task { await retry(item) } })
                            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("下载列表（\(store.items.count)）")
                } footer: {
                    Text("文件位置：文件 App → 在我的 iPhone 上 → 后台下载 → Downloads。")
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("下载")
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .task { BackgroundDownloader.shared.reconnect() }
    }

    @MainActor
    private func addDownload() async {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isPreparing = true
        defer { isPreparing = false }
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else {
            show(DownloadError.invalidLink)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let basename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let name = basename.isEmpty || basename == "/" ? "下载文件_\(UUID().uuidString.prefix(8))" : basename
        BackgroundDownloader.shared.enqueue(request: request, originalURL: raw, name: name, source: .direct)
        link = ""
    }

    @MainActor
    private func retry(_ item: DownloadItem) async {
        if item.source == .browser {
            show(DownloadError.unsupportedLink("网页登录下载通常依赖临时 Cookie/令牌。请返回浏览器页面重新点击下载按钮。"))
            return
        }
        guard let url = URL(string: item.originalURL), url.scheme?.lowercased() == "https", url.host != nil else {
            show(DownloadError.invalidLink)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        BackgroundDownloader.shared.enqueue(request: request, originalURL: item.originalURL, name: item.filename, source: .direct)
    }

    private func show(_ error: Error) {
        alertMessage = error.localizedDescription
        showAlert = true
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let fileURL: URL?
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "arrow.down.doc.fill")
                    .font(.title3)
                    .foregroundStyle(item.status == .completed ? .green : .blue)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.filename)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(item.sourceLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(item.status == .failed ? .red : .secondary)
                        Spacer()
                        if let progress = item.fraction, item.status == .running {
                            Text("\(Int(progress * 100))%")
                                .monospacedDigit()
                                .font(.caption.weight(.medium))
                        }
                    }
                }
            }
            if item.status == .running || item.status == .paused {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: item.fraction ?? 0)
                    Text("\(item.downloadedBytes.readableSize) / \(item.totalBytes.readableSize)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = item.errorMessage, item.status == .failed {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                switch item.status {
                case .running:
                    Button("暂停", action: pause)
                    Button("取消", role: .destructive, action: cancel)
                case .paused:
                    Button("继续", action: resume)
                    Button("取消", role: .destructive, action: cancel)
                case .failed, .cancelled:
                    Button("重试", action: retry)
                case .completed:
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("分享 / 存储", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.2))
        }
    }

    private var statusText: String {
        switch item.status {
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        case .cancelled: return "已取消"
        }
    }
}
