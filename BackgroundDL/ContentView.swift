import SwiftUI
import QuickLook

private enum MainTab: Hashable {
    case browser, downloads
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .browser
    @State private var sharedURL: URL?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { BrowserView(sharedURL: sharedURL) }
                .tabItem { Label("浏览器", systemImage: "safari") }
                .tag(MainTab.browser)
            NavigationStack { DownloadListView() }
                .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
                .tag(MainTab.downloads)
        }
        .tint(.cyan)
        .onAppear(perform: acceptSharedLink)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { acceptSharedLink() }
        }
    }

    private func acceptSharedLink() {
        guard let url = SharedLinkInbox.takeNext() else { return }
        sharedURL = url
        selectedTab = .browser
    }
}

private enum DownloadSort: String, CaseIterable {
    case newest = "最新优先"
    case oldest = "最早优先"
    case name = "文件名"
    case size = "文件大小"
}

private enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case active = "进行中"
    case completed = "已完成"
    var id: String { rawValue }
    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return item.status == .running || item.status == .paused || item.status == .failed
        case .completed: return item.status == .completed
        }
    }
}

// Confirmation state belongs to the stable screen, never to a swiped or reordered row.
private enum PendingDeletion {
    case item(id: UUID, filename: String, deleteFile: Bool)
}

private struct DownloadListView: View {
    @ObservedObject private var store = DownloadStore.shared
    @State private var filter: DownloadFilter = .all
    @State private var pendingDeletion: PendingDeletion?
    @State private var showClearCompleted = false
    @State private var showDirectInput = false
    @State private var link = ""
    @State private var searchText = ""
    @State private var sortOrder: DownloadSort = .newest
    @AppStorage("bgdl.downloadMode") private var downloadMode = "smart"
    @AppStorage("bgdl.notifyDownloads") private var notifyDownloads = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    private var visibleItems: [DownloadItem] {
        let candidates = store.items.filter { filter.includes($0) &&
            (searchText.isEmpty || $0.filename.localizedCaseInsensitiveContains(searchText)) }
        switch sortOrder {
        case .newest: return candidates.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return candidates.sorted { $0.createdAt < $1.createdAt }
        case .name: return candidates.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .size: return candidates.sorted { $0.totalBytes > $1.totalBytes }
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Label("\(store.runningCount) 项下载中", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Label(store.aggregateSpeedLabel, systemImage: "speedometer")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .listRowBackground(Color.clear)
                .padding(.vertical, 2)

                Picker("状态", selection: $filter) {
                    ForEach(DownloadFilter.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if visibleItems.isEmpty {
                Section {
                    ContentUnavailableView(filter == .all ? "暂无下载" : "暂无相关任务",
                                           systemImage: "arrow.down.doc",
                                           description: Text("在浏览器中打开分享链接，点击网页下载即可。"))
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(visibleItems) { item in
                        CompactDownloadRow(item: item,
                                           fileURL: store.fileURL(for: item),
                                           pause: { DownloadCoordinator.shared.changeState(id: item.id, action: .pause) },
                                           resume: { DownloadCoordinator.shared.changeState(id: item.id, action: .resume) },
                                           cancel: { DownloadCoordinator.shared.changeState(id: item.id, action: .cancel) },
                                           retry: { retry(item) },
                                           requestRemove: { deleteFile in requestRemoval(id: item.id, filename: item.filename, deleteFile: deleteFile) },
                                           pendingDeletion: $pendingDeletion,
                                           confirmRemoval: confirmRemoval,
                                           rename: { name in try store.renameCompleted(id: item.id, to: name) })
                    }
                } header: {
                    HStack {
                        Text("下载任务")
                        Spacer()
                        Text("\(visibleItems.count) 项")
                    }
                } footer: {
                    Text("左滑可暂停、继续或删除；长按任务可管理文件。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu("下载模式") {
                        ForEach(DownloadMode.allCases) { mode in
                            Button {
                                downloadMode = mode.rawValue
                            } label: {
                                Label(mode.label, systemImage: downloadMode == mode.rawValue ? "checkmark" : "circle")
                            }
                        }
                    }
                    Menu("排序方式") {
                        ForEach(DownloadSort.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                Label(order.rawValue, systemImage: sortOrder == order ? "checkmark" : "circle")
                            }
                        }
                    }
                    Toggle(isOn: $notifyDownloads) {
                        Label("完成/失败通知", systemImage: "bell")
                    }
                    Button { showDirectInput = true } label: { Label("添加直链", systemImage: "plus") }
                    Button { showClearCompleted = true } label: { Label("清理已完成记录", systemImage: "checkmark.circle") }
                        .disabled(store.completedCount == 0)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        // Bulk cleanup is a screen-level operation. Item confirmations are anchored
        // to their individual row with a genuine popover (see CompactDownloadRow).
        .confirmationDialog("清理已完成下载", isPresented: $showClearCompleted, titleVisibility: .visible) {
            Button("仅清理已完成记录") { clearCompleted(false) }
            Button("连同已完成文件一起删除", role: .destructive) { clearCompleted(true) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("默认保留已经下载到“文件”App 的本地文件。")
        }
        .alert("添加 HTTPS 直链", isPresented: $showDirectInput) {
            TextField("https://…", text: $link)
                .textInputAutocapitalization(.never)
            Button("开始下载") { startDirectDownload() }
            Button("取消", role: .cancel) { }
        } message: { Text("普通网页分享链接请从浏览器打开。") }
        .alert("操作提示", isPresented: $showAlert) { Button("确定", role: .cancel) { } } message: { Text(alertMessage) }
        .task { DownloadCoordinator.shared.reconnect() }
        .onChange(of: notifyDownloads) { _, enabled in
            if enabled { DownloadNotifications.requestPermission() }
        }
        .searchable(text: $searchText, prompt: "搜索下载文件")
    }

    @MainActor private func startDirectDownload() {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else {
            show(DownloadError.invalidLink); return
        }
        let filename = url.lastPathComponent.isEmpty ? "下载文件" : url.lastPathComponent
        DownloadCoordinator.shared.enqueue(request: URLRequest(url: url), originalURL: raw, name: filename, source: .direct)
        link = ""
    }

    @MainActor private func retry(_ item: DownloadItem) {
        if SegmentedDownloader.shared.contains(id: item.id) {
            SegmentedDownloader.shared.retry(id: item.id)
            return
        }
        guard item.source == .direct else {
            show(DownloadError.unsupportedLink("此文件来自网页下载，请返回网页重新点击下载按钮。")); return
        }
        guard let url = URL(string: item.originalURL), url.scheme == "https" else {
            show(DownloadError.invalidLink); return
        }
        DownloadCoordinator.shared.enqueue(request: URLRequest(url: url), originalURL: item.originalURL,
                                             name: item.filename, source: .direct)
    }

    @MainActor private func requestRemoval(id: UUID, filename: String, deleteFile: Bool) {
        // Let the swipe action or context menu fully close before presenting a
        // row-anchored popover; do not attach a dialog to the transient swipe button.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard store.items.contains(where: { $0.id == id }) else { return }
            pendingDeletion = .item(id: id, filename: filename, deleteFile: deleteFile)
        }
    }

    @MainActor private func confirmRemoval() {
        guard case let .item(id, _, deleteFile) = pendingDeletion else { return }
        // Dismiss the native popover before removing its presenting row.
        pendingDeletion = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard store.items.contains(where: { $0.id == id }) else { return }
            do { try DownloadCoordinator.shared.remove(id: id, deleteFile: deleteFile) }
            catch { show(error) }
        }
    }

    @MainActor private func clearCompleted(_ deleteFiles: Bool) {
        do { try store.clearCompleted(deleteFiles: deleteFiles) } catch { show(error) }
    }
    private func show(_ error: Error) { alertMessage = error.localizedDescription; showAlert = true }
}

private struct CompactDownloadRow: View {
    let item: DownloadItem
    let fileURL: URL?
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let requestRemove: (Bool) -> Void
    @Binding var pendingDeletion: PendingDeletion?
    let confirmRemoval: () -> Void
    let rename: (String) throws -> Void

    @State private var showRename = false
    @State private var newName = ""
    @State private var showError = false
    @State private var errorText = ""
    @State private var previewURL: URL?

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "doc.zipper")
                .font(.title2)
                .foregroundStyle(item.status == .completed ? .green : .cyan)
                .frame(width: 29)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let progress = item.fraction, item.status == .running || item.status == .paused {
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if item.status == .running || item.status == .paused {
                    ProgressView(value: item.fraction ?? 0)
                        .tint(.cyan)
                        .frame(height: 4)
                    HStack(spacing: 5) {
                        Text("\(item.downloadedBytes.readableSize) / \(item.totalBytes.readableSize)")
                        Spacer(minLength: 4)
                        Text(item.status == .paused ? "已暂停" : item.speedLabel)
                        Text("·")
                        Text(item.etaLabel)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                } else {
                    Text(item.status == .completed ? "已完成 · \(item.downloadedBytes.readableSize)" : (item.errorMessage ?? stateText))
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? .red : .secondary)
                        .lineLimit(1)
                }
            }
            Menu {
                if item.status == .running { Button("暂停", systemImage: "pause.fill", action: pause) }
                if item.status == .paused { Button("继续", systemImage: "play.fill", action: resume) }
                if item.status == .failed || item.status == .cancelled { Button("重试", systemImage: "arrow.clockwise", action: retry) }
                if item.status == .running || item.status == .paused { Button("取消下载", systemImage: "xmark", role: .destructive, action: cancel) }
                if item.status == .completed {
                    Button { newName = item.savedFilename ?? item.filename; showRename = true } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    if let fileURL {
                        Button { previewURL = fileURL } label: { Label("预览文件", systemImage: "eye") }
                        ShareLink(item: fileURL) { Label("分享文件", systemImage: "square.and.arrow.up") }
                    }
                }
                Button { requestRemove(false) } label: {
                    Label("移除记录", systemImage: "trash")
                }
                if item.status == .completed {
                    Button { requestRemove(true) } label: {
                        Label("删除文件和记录", systemImage: "trash.fill")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("管理 \(item.filename)")
        }
        .padding(.vertical, 5)
        .contextMenu {
            if item.status == .running { Button("暂停", action: pause) }
            if item.status == .paused { Button("继续", action: resume) }
            if item.status == .completed {
                Button("重命名") { newName = item.savedFilename ?? item.filename; showRename = true }
            }
            Button("移除记录") { requestRemove(false) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // This is a request, not an immediate destructive mutation.
            // Do not use role: .destructive here: SwiftUI can animate/remove a row
            // while the confirmation dialog is still being presented.
            Button { requestRemove(false) } label: {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
            if item.status == .running { Button("暂停", action: pause).tint(.orange) }
            if item.status == .paused { Button("继续", action: resume).tint(.cyan) }
        }
        // Attachment is the stable ForEach row, not the ephemeral swipe-action
        // control or the top navigation toolbar. Parent owns the state.
        .popover(isPresented: Binding(
            get: {
                if case .item(let id, _, _) = pendingDeletion { return id == item.id }
                return false
            },
            set: { presented in
                guard !presented else { return }
                if case .item(let id, _, _) = pendingDeletion, id == item.id {
                    pendingDeletion = nil
                }
            }
        ), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            if case let .item(id, filename, deleteFile) = pendingDeletion, id == item.id {
                DownloadDeletionPopover(
                    filename: filename,
                    deleteFile: deleteFile,
                    onConfirm: confirmRemoval,
                    onCancel: { pendingDeletion = nil }
                )
                .presentationCompactAdaptation(.popover)
            }
        }
        .alert("重命名文件", isPresented: $showRename) {
            TextField("文件名", text: $newName)
            Button("保存") { do { try rename(newName) } catch { report(error) } }
            Button("取消", role: .cancel) { }
        }
        .quickLookPreview($previewURL)
        .alert("操作失败", isPresented: $showError) { Button("确定", role: .cancel) {} } message: { Text(errorText) }
    }

    private var stateText: String {
        switch item.status {
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        case .cancelled: return "已取消"
        }
    }
    private func report(_ error: Error) { errorText = error.localizedDescription; showError = true }
}

private struct DownloadDeletionPopover: View {
    let filename: String
    let deleteFile: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(deleteFile ? "删除下载文件？" : "移除下载记录？", systemImage: "trash")
                .font(.headline)
            Text(filename)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(deleteFile
                 ? "将永久删除本地文件及记录，此操作不可撤销。"
                 : "保留已下载文件，仅移除列表记录。正在运行的任务会停止。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive, action: onConfirm) {
                Text(deleteFile ? "删除文件与记录" : "确认移除记录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button("取消", action: onCancel)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .padding(18)
        .frame(width: 300)
    }
}
