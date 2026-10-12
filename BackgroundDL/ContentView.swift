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
        ScrollView {
            VStack(spacing: 16) {
                DownloadOverviewCard(runningCount: store.runningCount,
                                     completedCount: store.completedCount,
                                     speedLabel: store.aggregateSpeedLabel)
                if store.items.isEmpty {
                    ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.doc",
                                           description: Text("去“浏览器”打开分享网页，直接点击网站自己的下载按钮。"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 14) {
                        HStack {
                            Text("下载队列")
                                .font(.title3.bold())
                            Spacer()
                            Text("共 \(store.items.count) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(store.items) { item in
                            DownloadRow(item: item,
                                        fileURL: store.fileURL(for: item),
                                        pause: { BackgroundDownloader.shared.changeState(id: item.id, action: .pause) },
                                        resume: { BackgroundDownloader.shared.changeState(id: item.id, action: .resume) },
                                        cancel: { BackgroundDownloader.shared.changeState(id: item.id, action: .cancel) },
                                        retry: { Task { await retry(item) } })
                        }
                    }
                }

                DisclosureGroup("手动添加 HTTPS 直链") {
                    DirectLinkCard(link: $link, isPreparing: isPreparing) {
                        Task { await addDownload() }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("文件位置：文件 App → 在我的 iPhone 上 → 后台下载 → Downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.large)
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .task { BackgroundDownloader.shared.reconnect() }
    }

    private var background: some View {
        LinearGradient(colors: [Color.cyan.opacity(0.16), Color.blue.opacity(0.08), Color(uiColor: .systemBackground)],
                       startPoint: .top,
                       endPoint: .bottom)
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
            show(DownloadError.unsupportedLink("网页登录下载依赖临时 Cookie/令牌。请返回浏览器页面重新点击下载按钮。"))
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

private struct DownloadOverviewCard: View {
    let runningCount: Int
    let completedCount: Int
    let speedLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("下载概览")
                        .font(.title2.bold())
                    Text("后台传输 · 速度与剩余时间根据最新进度估算")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.cyan)
            }
            HStack(spacing: 12) {
                MetricPill(title: "进行中", value: "\(runningCount)", icon: "bolt.fill")
                MetricPill(title: "已完成", value: "\(completedCount)", icon: "checkmark.circle.fill")
                MetricPill(title: "总速度", value: speedLabel, icon: "speedometer")
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
    }
}

private struct MetricPill: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DirectLinkCard: View {
    @Binding var link: String
    let isPreparing: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("备用直链")
                .font(.headline)
            TextField("粘贴 HTTPS 直链（可选）", text: $link, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .lineLimit(2...4)
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button(action: action) {
                HStack {
                    Label("开始后台下载", systemImage: "arrow.down.circle.fill")
                    Spacer()
                    if isPreparing { ProgressView() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPreparing || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("更推荐用浏览器页：打开分享网页，直接点站点自己的下载按钮。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "doc.zipper")
                    .font(.title2)
                    .foregroundStyle(item.status == .completed ? .green : .cyan)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.filename)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        StatusChip(text: item.sourceLabel, tint: .gray)
                        StatusChip(text: statusText, tint: statusTint)
                        Spacer()
                        if let progress = item.fraction {
                            Text("\(Int(progress * 100))%")
                                .font(.headline.monospacedDigit())
                        }
                    }
                }
            }

            if item.status == .running || item.status == .paused || item.status == .completed {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: item.fraction ?? 0)
                        .tint(.cyan)
                    HStack {
                        Text("\(item.downloadedBytes.readableSize) / \(item.totalBytes.readableSize)")
                        Spacer()
                        Text(item.createdAt, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if item.status == .running || item.status == .paused {
                        HStack(spacing: 12) {
                            InfoBadge(icon: "speedometer", text: item.speedLabel)
                            InfoBadge(icon: "clock", text: item.etaLabel)
                        }
                    }
                }
            }

            if let error = item.errorMessage, item.status == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                switch item.status {
                case .running:
                    ActionButton(title: "暂停", icon: "pause.fill", tint: .orange, action: pause)
                    ActionButton(title: "取消", icon: "xmark", tint: .red, action: cancel)
                case .paused:
                    ActionButton(title: "继续", icon: "play.fill", tint: .cyan, action: resume)
                    ActionButton(title: "取消", icon: "xmark", tint: .red, action: cancel)
                case .failed, .cancelled:
                    ActionButton(title: "重试", icon: "arrow.clockwise", tint: .cyan, action: retry)
                case .completed:
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("分享 / 存储", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.16))
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

    private var statusTint: Color {
        switch item.status {
        case .running: return .cyan
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

private struct StatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct InfoBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }
}
