import SwiftUI

struct ContentView: View {
    @ObservedObject private var store = DownloadStore.shared
    @StateObject private var drive = GoogleDriveService()
    @State private var link = ""
    @State private var isPreparing = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴 HTTPS 直链或 Google Drive 文件链接", text: $link, axis: .vertical)
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
                    .disabled(isPreparing || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("新建下载")
                } footer: {
                    Text("先在前台发起任务，然后可以切换 App 或锁屏；不要上滑强制关闭本 App。")
                }

                Section("Google Drive 授权") {
                    Text(drive.accountLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("登录 Google") {
                            Task { await googleSignIn() }
                        }
                        Spacer()
                        Button("退出") { drive.signOut() }
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if store.items.isEmpty {
                        ContentUnavailableView("暂无下载任务", systemImage: "square.and.arrow.down",
                                               description: Text("粘贴文件链接即可开始下载。"))
                    }
                    ForEach(store.items) { item in
                        DownloadRow(item: item, fileURL: store.fileURL(for: item),
                                    pause: { BackgroundDownloader.shared.changeState(id: item.id, action: .pause) },
                                    resume: { BackgroundDownloader.shared.changeState(id: item.id, action: .resume) },
                                    cancel: { BackgroundDownloader.shared.changeState(id: item.id, action: .cancel) },
                                    retry: { Task { await retry(item) } })
                    }
                } header: {
                    Text("下载列表（\(store.items.count)）")
                } footer: {
                    Text("下载后的文件：文件 App → 在我的 iPhone 上 → 后台下载 → Downloads。")
                }
            }
            .navigationTitle("后台下载")
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .task {
                await drive.restore()
                BackgroundDownloader.shared.reconnect()
            }
        }
    }

    @MainActor
    private func addDownload() async {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            let prepared = try await drive.prepare(raw)
            BackgroundDownloader.shared.enqueue(request: prepared.request, originalURL: raw,
                                                 name: prepared.name, source: prepared.source)
            link = ""
        } catch {
            show(error)
        }
    }

    @MainActor
    private func retry(_ item: DownloadItem) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            // 重新请求 Google Token，避免旧授权头过期。
            let prepared = try await drive.prepare(item.originalURL)
            BackgroundDownloader.shared.enqueue(request: prepared.request,
                                                 originalURL: item.originalURL,
                                                 name: prepared.name, source: prepared.source)
        } catch { show(error) }
    }

    @MainActor
    private func googleSignIn() async {
        do { try await drive.signIn() }
        catch { show(error) }
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
        VStack(alignment: .leading, spacing: 8) {
            Text(item.filename)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .textSelection(.enabled)
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
                Spacer()
                if let progress = item.fraction, item.status == .running {
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit().font(.caption)
                }
            }
            if item.status == .running {
                if let progress = item.fraction {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                Text("\(item.downloadedBytes.readableSize) / \(item.totalBytes.readableSize)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = item.errorMessage, item.status == .failed {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            HStack(spacing: 20) {
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
        .padding(.vertical, 5)
    }

    private var statusText: String {
        switch item.status {
        case .running: "下载中"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed: "下载失败"
        case .cancelled: "已取消"
        }
    }
}
