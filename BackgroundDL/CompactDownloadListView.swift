import SwiftUI

private enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "全部", active = "进行中", done = "已完成"
    var id: String { rawValue }
    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return item.status != .completed && item.status != .cancelled
        case .done: return item.status == .completed
        }
    }
}

struct CompactDownloadListView: View {
    @ObservedObject private var store = DownloadStore.shared
    @State private var filter: DownloadFilter = .all
    @State private var showClean = false
    @State private var showInput = false
    @State private var link = ""
    @State private var errorText = ""
    @State private var showError = false

    var body: some View {
        List {
            HStack {
                Label("\(store.runningCount) 个下载中", systemImage: "arrow.down.circle")
                Spacer()
                Label(store.aggregateSpeedLabel, systemImage: "speedometer")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .listRowBackground(Color.clear)
            Picker("筛选", selection: $filter) {
                ForEach(DownloadFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            Section {
                let visible = store.items.filter { filter.matches($0) }
                if visible.isEmpty {
                    ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.doc",
                        description: Text("网页内点击下载，或从 Safari 分享链接到本 App。"))
                }
                ForEach(visible) { item in
                    CompactDownloadItem(item: item,
                        fileURL: store.fileURL(for: item),
                        retry: { retry(item) },
                        remove: { deleteFile in
                            try BackgroundDownloader.shared.remove(id: item.id, deleteFile: deleteFile)
                        },
                        rename: { name in try store.renameCompleted(id: item.id, to: name) })
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 11))
                }
            } header: {
                Text("任务")
            } footer: {
                Text("左滑暂停或移除，长按文件可管理；移除记录不会删除已下载文件。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showInput = true } label: { Label("添加直链", systemImage: "plus") }
                    Button { showClean = true } label: { Label("清理已完成", systemImage: "checkmark.circle") }
                        .disabled(store.completedCount == 0)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("清理已完成文件", isPresented: $showClean) {
            Button("仅移除记录") { clear(false) }
            Button("记录和本地文件一起删除", role: .destructive) { clear(true) }
        } message: { Text("默认保留已下载的文件。") }
        .alert("添加 HTTPS 文件直链", isPresented: $showInput) {
            TextField("https://…", text: $link)
            Button("添加") { addDirect() }
            Button("取消", role: .cancel) { }
        } message: { Text("分享网页链接请从浏览器打开。") }
        .alert("提示", isPresented: $showError) { Button("确定", role: .cancel) { } }
          message: { Text(errorText) }
        .task { BackgroundDownloader.shared.reconnect() }
    }

    private func show(_ error: Error) { errorText = error.localizedDescription; showError = true }
    private func clear(_ deleteFiles: Bool) {
        do { try store.clearCompleted(deleteFiles: deleteFiles) } catch { show(error) }
    }
    private func addDirect() {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil else {
            show(DownloadError.invalidLink); return
        }
        let name = url.lastPathComponent.isEmpty ? "下载文件" : url.lastPathComponent
        BackgroundDownloader.shared.enqueue(request: URLRequest(url: url),
            originalURL: raw, name: name, source: .direct)
        link = ""
    }
    private func retry(_ item: DownloadItem) {
        guard item.source == .direct, let url = URL(string: item.originalURL),
              url.scheme == "https" else {
            show(DownloadError.unsupportedLink("网页授权可能过期，请在浏览器中重新点击下载。")); return
        }
        BackgroundDownloader.shared.enqueue(request: URLRequest(url: url),
            originalURL: item.originalURL, name: item.filename, source: .direct)
    }
}

private struct CompactDownloadItem: View {
    let item: DownloadItem
    let fileURL: URL?
    let retry: () -> Void
    let remove: (Bool) throws -> Void
    let rename: (String) throws -> Void
    @State private var deleteLocal = false
    @State private var confirmRemove = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var errorText = ""
    @State private var showError = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "doc.zipper")
                .font(.title2)
                .foregroundStyle(item.status == .completed ? .green : .cyan)
                .frame(width: 27)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.filename)
                        .font(.subheadline.weight(.semibold))
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    if let fraction = item.fraction, item.status == .running || item.status == .paused {
                        Text("\(Int(fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if item.status == .running || item.status == .paused {
                    ProgressView(value: item.fraction ?? 0).tint(.cyan).frame(height: 4)
                    HStack(spacing: 4) {
                        Text("\(item.downloadedBytes.readableSize) / \(item.totalBytes.readableSize)")
                        Spacer(minLength: 3)
                        Text(item.status == .paused ? "暂停" : item.speedLabel)
                        Text("·")
                        Text(item.etaLabel)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                } else {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? .red : .secondary)
                        .lineLimit(1)
                }
            }
            Menu {
                if item.status == .running {
                    Button { operate(.pause) } label: { Label("暂停", systemImage: "pause.fill") }
                }
                if item.status == .paused {
                    Button { operate(.resume) } label: { Label("继续", systemImage: "play.fill") }
                }
                if item.status == .failed || item.status == .cancelled {
                    Button("重试", action: retry)
                }
                if item.status == .running || item.status == .paused {
                    Button(role: .destructive) { operate(.cancel) } label: {
                        Label("取消下载", systemImage: "xmark")
                    }
                }
                if item.status == .completed {
                    Button {
                        newName = item.savedFilename ?? item.filename
                        showRename = true
                    } label: { Label("重命名", systemImage: "pencil") }
                    if let fileURL {
                        ShareLink(item: fileURL) { Label("分享文件", systemImage: "square.and.arrow.up") }
                    }
                    Button(role: .destructive) {
                        deleteLocal = true; confirmRemove = true
                    } label: { Label("删除本地文件", systemImage: "trash.fill") }
                }
                Button(role: .destructive) {
                    deleteLocal = false; confirmRemove = true
                } label: { Label("移除记录", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 38)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if item.status == .running { Button("暂停") { operate(.pause) } }
            if item.status == .paused { Button("继续") { operate(.resume) } }
            if item.status == .completed {
                Button("重命名") { newName = item.savedFilename ?? item.filename; showRename = true }
            }
            Button("移除记录", role: .destructive) {
                deleteLocal = false; confirmRemove = true
            }
        }
        .swipeActions(edge: .trailing) {
            Button("移除", role: .destructive) { deleteLocal = false; confirmRemove = true }
            if item.status == .running {
                Button("暂停") { operate(.pause) }.tint(.orange)
            } else if item.status == .paused {
                Button("继续") { operate(.resume) }.tint(.cyan)
            }
        }
        .confirmationDialog("确认操作", isPresented: $confirmRemove) {
            Button(deleteLocal ? "删除文件和记录" : "仅移除记录", role: .destructive) {
                do { try remove(deleteLocal) } catch { report(error) }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(deleteLocal ? "本地文件将被永久删除。" : "下载记录将删除；本地已完成文件保留。")
        }
        .alert("重命名已完成文件", isPresented: $showRename) {
            TextField("文件名", text: $newName)
            Button("保存") {
                do { try rename(newName) } catch { report(error) }
            }
            Button("取消", role: .cancel) { }
        }
        .alert("操作失败", isPresented: $showError) { Button("确定", role: .cancel) { } }
          message: { Text(errorText) }
    }
    private var summary: String {
        switch item.status {
        case .completed: return "已完成 · \(item.downloadedBytes.readableSize)"
        case .failed: return item.errorMessage ?? "下载失败"
        case .cancelled: return "已取消"
        case .paused: return "已暂停"
        case .running: return "下载中"
        }
    }
    private func operate(_ action: DownloadAction) {
        BackgroundDownloader.shared.changeState(id: item.id, action: action)
    }
    private func report(_ error: Error) { errorText = error.localizedDescription; showError = true }
}
