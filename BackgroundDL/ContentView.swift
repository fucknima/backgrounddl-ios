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
    @State private var showLocalFiles = false
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
                    Button { showLocalFiles = true } label: { Label("本地文件管理", systemImage: "folder") }
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
        .sheet(isPresented: $showLocalFiles) {
            NavigationStack { LocalDownloadFilesView() }
        }
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
            Button("仅移除记录") { requestRemove(false) }
            if item.status == .completed {
                Button("删除本地文件与记录") { requestRemove(true) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // This is a request, not an immediate destructive mutation.
            // Do not use role: .destructive here: SwiftUI can animate/remove a row
            // while the confirmation dialog is still being presented.
            Button { requestRemove(item.status == .completed) } label: {
                Label(item.status == .completed ? "删除文件" : "移除任务", systemImage: "trash")
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


private struct LocalDownloadFile: Identifiable {
    let url: URL
    let bytes: Int64
    let recorded: Bool
    var id: URL { url }
    var filename: String { url.lastPathComponent }
}

private struct LocalDownloadFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DownloadStore.shared
    @State private var files: [LocalDownloadFile] = []
    @State private var pendingDelete: LocalDownloadFile?
    @State private var deletionError = ""
    @State private var showError = false
    @State private var previewURL: URL?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("共 \(files.count) 个文件")
                    Spacer()
                    Text(files.reduce(Int64(0)) { $0 + $1.bytes }.readableSize)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            } footer: {
                Text("此处直接读取“文件”App → 在我的 iPhone 上 → 后台下载 → Downloads，包括记录已移除但仍保存在设备上的文件。")
            }
            if files.isEmpty {
                ContentUnavailableView("暂无本地下载文件", systemImage: "folder",
                                       description: Text("下载完成后的文件会显示在这里。"))
            } else {
                Section("下载文件") {
                    ForEach(files) { file in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.cyan)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.filename)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Text("\(file.bytes.readableSize) · \(file.recorded ? "有下载记录" : "无对应记录")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button { previewURL = file.url } label: {
                                Image(systemName: "eye")
                                    .frame(width: 32, height: 40)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("预览 \(file.filename)")
                            Button { pendingDelete = file } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                    .frame(width: 32, height: 40)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除 \(file.filename)")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("本地文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("刷新", systemImage: "arrow.clockwise") { reload() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear(perform: reload)
        .alert("永久删除本地文件？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { file in
            Button("删除文件", role: .destructive) { delete(file) }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { file in
            Text("将永久删除“\(file.filename)”，如果存在对应的下载记录，也会一并移除。这不会进入系统“最近删除”。")
        }
        .alert("删除失败", isPresented: $showError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(deletionError)
        }
        .quickLookPreview($previewURL)
    }

    @MainActor private func reload() {
        let folder = DownloadStore.downloadFolder
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let recorded = Set(store.items.compactMap { $0.savedFilename })
        files = urls.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map {
            let bytes = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return LocalDownloadFile(url: $0, bytes: bytes, recorded: recorded.contains($0.lastPathComponent))
        }.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    @MainActor private func delete(_ file: LocalDownloadFile) {
        pendingDelete = nil
        let folder = DownloadStore.downloadFolder.standardizedFileURL
        let actual = file.url.standardizedFileURL
        guard actual.deletingLastPathComponent() == folder else {
            deletionError = "文件路径异常，已拒绝删除。"
            showError = true
            return
        }
        do {
            if let item = store.items.first(where: { $0.savedFilename == file.filename }) {
                try DownloadCoordinator.shared.remove(id: item.id, deleteFile: true)
            } else {
                try FileManager.default.removeItem(at: actual)
            }
            // Never announce success based solely on a removed list row.
            guard !FileManager.default.fileExists(atPath: actual.path) else {
                throw NSError(domain: "BackgroundDL", code: 90,
                              userInfo: [NSLocalizedDescriptionKey: "删除操作结束后文件仍存在。"])
            }
            reload()
        } catch {
            deletionError = error.localizedDescription
            showError = true
            reload()
        }
    }
}
