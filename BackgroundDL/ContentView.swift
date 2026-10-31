import SwiftUI
import QuickLook
import UniformTypeIdentifiers

private enum MainTab: Hashable {
    case browser, downloads, settings
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .browser
    @State private var sharedURL: URL?
    @State private var incomingLinkRevision = UUID()
    @ObservedObject private var incomingRouter = IncomingLinkRouter.shared
    @State private var lastConsumedRevision: UUID?
    @State private var isDropTargeted = false
    @State private var linkError = ""
    @State private var showLinkError = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                BrowserView(sharedURL: sharedURL, openDownloads: {
                    selectedTab = .downloads
                }, incomingLinkRevision: incomingLinkRevision,
                   acceptDroppedProviders: { providers in importDrop(providers) })
            }
                .tabItem { Label("浏览器", systemImage: "safari") }
                .tag(MainTab.browser)
            NavigationStack { DownloadListView() }
                .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
                .tag(MainTab.downloads)
            NavigationStack { DownloadSettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .tint(.cyan)
        // Receives system-delivered URL documents, including candidates dropped
        // onto the app icon when iOS elects to dispatch them to third-party apps.
        .onOpenURL { url in incomingRouter.receive(url, from: "SwiftUI onOpenURL") }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                incomingRouter.receive(url, from: "SwiftUI 用户活动")
            } else {
                incomingRouter.note("SwiftUI 用户活动没有网页链接")
            }
        }
        // Also accepts links dropped after the app has opened. The separate
        // SwiftUI drop target is a fallback for origins that offer plain text.
        .onDrop(of: [UTType.url, UTType.fileURL, UTType.plainText], isTargeted: $isDropTargeted) { providers in
            importDrop(providers)
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                Label("松手打开链接", systemImage: "link")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .allowsHitTesting(false)
            }
        }
        .alert("无法打开链接", isPresented: $showLinkError) {
            Button("确定", role: .cancel) {}
        } message: { Text(linkError) }
        .onAppear {
            incomingRouter.note("主界面出现")
            acceptSharedLink()
            consumePendingLink()
        }
        .onChange(of: incomingRouter.revision) { _, _ in consumePendingLink() }
        .onChange(of: isDropTargeted) { _, targeted in
            if targeted { incomingRouter.note("拖放目标已进入") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                incomingRouter.note("App 回到前台")
                acceptSharedLink()
                consumePendingLink()
            }
        }
    }

    private func acceptSharedLink() {
        guard let url = SharedLinkInbox.takeNext() else { return }
        incomingRouter.receive(url, from: "系统分享收件箱")
    }

    private func consumePendingLink() {
        guard let url = incomingRouter.latestURL,
              lastConsumedRevision != incomingRouter.revision else { return }
        lastConsumedRevision = incomingRouter.revision
        sharedURL = url
        incomingLinkRevision = UUID()
        selectedTab = .browser
        incomingRouter.note("浏览器已打开：\(url.host ?? "网页")")
    }

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        let typeNames = providers.flatMap { $0.registeredTypeIdentifiers }.joined(separator: ",")
        incomingRouter.note("onDrop 收到 \(providers.count) 项：\(String(typeNames.prefix(110)))")
        return DroppedLinkReader.load(providers: providers, note: { event in
            incomingRouter.note(event)
        }, completion: { resolved in
            if let resolved {
                incomingRouter.receive(resolved, from: "App 内 onDrop")
            } else {
                incomingRouter.note("拖放全部读取方式均失败")
                linkError = "未能提取有效网址，请到「设置 → 拖放诊断」查看各读取方式的结果。"
                showLinkError = true
            }
        })
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

private struct DetailSelection: Identifiable {
    let id: UUID
}

private struct DownloadListView: View {
    @ObservedObject private var store = DownloadStore.shared
    @State private var filter: DownloadFilter = .all
    @State private var selectedDetail: DetailSelection?
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
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 6) {
                    Label("\(store.runningCount) 下载中", systemImage: "arrow.down.circle")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 6)
                    Label(store.aggregateSpeedLabel, systemImage: "speedometer")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("\(store.completedCount) 已完成")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
                .monospacedDigit()
                Picker("状态", selection: $filter) {
                    ForEach(DownloadFilter.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("downloadFilter")
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(Color(uiColor: .secondarySystemBackground))

            if visibleItems.isEmpty {
                Spacer(minLength: 20)
                ContentUnavailableView(
                    searchText.isEmpty ? (filter == .all ? "暂无下载" : "没有相关任务") : "没有匹配的下载",
                    systemImage: searchText.isEmpty ? "arrow.down.doc" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "打开分享链接或添加 HTTPS 直链即可开始下载。" : "试试其他文件名。")
                )
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(visibleItems) { item in
                        CompactDownloadRow(item: item,
                                           fileURL: store.fileURL(for: item),
                                           pause: { DownloadCoordinator.shared.changeState(id: item.id, action: .pause) },
                                           resume: { DownloadCoordinator.shared.changeState(id: item.id, action: .resume) },
                                           cancel: { DownloadCoordinator.shared.changeState(id: item.id, action: .cancel) },
                                           retry: { retry(item) },
                                           remove: { deleteFile in deleteImmediately(id: item.id, deleteFile: deleteFile) },
                                           openDetails: { selectedDetail = DetailSelection(id: item.id) },
                                           rename: { name in try store.renameCompleted(id: item.id, to: name) })
                        .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu {
                        ForEach(DownloadMode.allCases) { mode in
                            Button {
                                downloadMode = mode.rawValue
                            } label: {
                                Label(mode.label, systemImage: downloadMode == mode.rawValue ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        Label("下载模式", systemImage: "arrow.down.circle")
                    }
                    Menu {
                        ForEach(DownloadSort.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                Label(order.rawValue, systemImage: sortOrder == order ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        Label("排序方式", systemImage: "arrow.up.arrow.down")
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
        .confirmationDialog("清理已完成下载", isPresented: $showClearCompleted) {
            Button("仅清理记录") { clearCompleted(false) }
            Button("删除本地文件与记录", role: .destructive) { clearCompleted(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清理记录不删除本地文件，删除文件后不可恢复。")
        }
        .sheet(item: $selectedDetail) { selection in
            NavigationStack { DownloadDetailView(itemID: selection.id) }
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

    @MainActor private func deleteImmediately(id: UUID, deleteFile: Bool) {
        // No confirmation: wait until the swipe action has dismissed, then remove
        // by stable UUID; if deleting the actual file fails, retain its record.
        DispatchQueue.main.async {
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
    let remove: (Bool) -> Void
    let openDetails: () -> Void
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
                    if item.status == .completed {
                        HStack(spacing: 6) {
                            Text("已完成 · \(item.downloadedBytes.readableSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(item.completedAt.map {
                                $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                            } ?? "时间未知")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    } else {
                        Text(item.errorMessage ?? stateText)
                            .font(.caption)
                            .foregroundStyle(item.status == .failed ? .red : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openDetails)
            Menu {
                Button { openDetails() } label: { Label("任务详情", systemImage: "info.circle") }
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
                Button { remove(false) } label: {
                    Label("移除记录", systemImage: "trash")
                }
                if item.status == .completed {
                    Button { remove(true) } label: {
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
            Button("仅移除记录") { remove(false) }
            if item.status == .completed {
                Button("删除本地文件与记录") { remove(true) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // A single tap deletes immediately; keeping full swipe disabled avoids
            // accidentally deleting the local file with an uncontrolled gesture.
            Button { remove(item.status == .completed) } label: {
                Label(item.status == .completed ? "删除" : "移除", systemImage: "trash")
            }
            .tint(.red)
            if item.status == .running { Button("暂停", action: pause).tint(.orange) }
            if item.status == .paused { Button("继续", action: resume).tint(.cyan) }
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

// A task is inspected by immutable UUID; every statistic is resolved from the live
// store, so background callbacks can update the sheet without stale row bindings.
private struct DownloadDetailView: View {
    let itemID: UUID
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DownloadStore.shared
    @State private var showingDelete = false
    @State private var showingRename = false
    @State private var newName = ""
    @State private var previewURL: URL?
    @State private var errorMessage = ""
    @State private var showError = false

    private var item: DownloadItem? { store.items.first(where: { $0.id == itemID }) }

    var body: some View {
        Group {
            if let item {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 11) {
                            HStack(spacing: 12) {
                                Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "arrow.down.doc.fill")
                                    .font(.system(size: 30)).foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.filename).font(.headline).lineLimit(3)
                                    Text(statusLabel(item)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if item.status == .running || item.status == .paused {
                                ProgressView(value: item.fraction ?? 0).tint(.cyan)
                                HStack {
                                    Text(item.downloadedBytes.readableSize)
                                    Spacer()
                                    Text(item.totalBytes.readableSize)
                                }
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 7)
                    }
                    Section("下载数据") {
                        LabeledContent("已传输", value: item.downloadedBytes.readableSize)
                        LabeledContent("总大小", value: item.totalBytes.readableSize)
                        LabeledContent("速度（最近回调）", value: item.speedLabel)
                        LabeledContent("预计剩余", value: item.etaLabel)
                        LabeledContent("重试次数", value: "\(item.retries ?? 0)")
                        if let last = item.lastProgressAt {
                            LabeledContent("最后进度回调", value: last.formatted(date: .omitted, time: .standard))
                        }
                        if let next = item.nextRetryAt {
                            LabeledContent("下次重试", value: next.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    Section("来源与存储") {
                        LabeledContent("下载方式", value:
                            SegmentedDownloader.shared.contains(id: item.id) ? "HTTP Range 分段" : "系统后台下载")
                        LabeledContent("来源", value: item.sourceLabel)
                        LabeledContent("建立日期", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if item.status == .completed {
                            LabeledContent("完成时间", value: item.completedAt.map {
                                $0.formatted(date: .abbreviated, time: .shortened)
                            } ?? "旧版没有记录")
                        }
                        LabeledContent("站点", value: URL(string: item.originalURL)?.host ?? "未知")
                        LabeledContent("保存文件", value: item.savedFilename ?? "尚未完成")
                        if item.status == .completed, store.fileURL(for: item) == nil {
                            Label("记录显示已完成，但本地文件不可用", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let error = item.errorMessage, !error.isEmpty {
                        Section("异常诊断") {
                            Text(error).font(.subheadline).foregroundStyle(.red)
                        }
                    }
                    Section("操作") {
                        if item.status == .running {
                            Button { DownloadCoordinator.shared.changeState(id: item.id, action: .pause) } label: {
                                Label("暂停下载", systemImage: "pause.fill")
                            }
                        } else if item.status == .paused {
                            Button { DownloadCoordinator.shared.changeState(id: item.id, action: .resume) } label: {
                                Label("继续下载", systemImage: "play.fill")
                            }
                        } else if item.status == .failed || item.status == .cancelled {
                            Button("重试此任务", systemImage: "arrow.clockwise") { retry(item) }
                        }
                        if let file = store.fileURL(for: item),
                           FileManager.default.fileExists(atPath: file.path) {
                            Button { previewURL = file } label: { Label("预览文件", systemImage: "eye") }
                            ShareLink(item: file) { Label("分享文件", systemImage: "square.and.arrow.up") }
                            Button {
                                newName = item.savedFilename ?? item.filename
                                showingRename = true
                            } label: { Label("重命名文件", systemImage: "pencil") }
                        }
                        ShareLink(item: diagnosticReport(item)) {
                            Label("分享诊断报告（不含完整下载链接）", systemImage: "doc.text.magnifyingglass")
                        }
                        Button(role: .destructive) { showingDelete = true } label: {
                            Label("删除任务…", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView("任务已移除", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        .confirmationDialog("如何处理这个任务？", isPresented: $showingDelete, titleVisibility: .visible) {
            if let item, item.status == .completed {
                Button("删除本地文件与记录", role: .destructive) { delete(item, file: true) }
            }
            Button("仅移除记录", role: .destructive) {
                if let item { delete(item, file: false) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除本地文件不可恢复；仅移除记录不会删除文件。")
        }
        .alert("重命名文件", isPresented: $showingRename) {
            TextField("新文件名", text: $newName)
            Button("保存") {
                do { try store.renameCompleted(id: itemID, to: newName) }
                catch { display(error) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("不填写扩展名时会保留原扩展名。") }
        .alert("操作失败", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: { Text(errorMessage) }
        .quickLookPreview($previewURL)
    }

    private func statusLabel(_ item: DownloadItem) -> String {
        switch item.status {
        case .running: return "正在下载"
        case .paused: return "已暂停"
        case .completed: return "下载完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private func diagnosticReport(_ item: DownloadItem) -> String {
        // Do not export signed URL query tokens, login cookies or credentials.
        [
            "BackgroundDL 2.0 下载诊断",
            "任务 ID: \(item.id.uuidString)",
            "文件: \(item.filename)",
            "网站: \(URL(string: item.originalURL)?.host ?? "未知")",
            "状态: \(statusLabel(item))",
            "已下载字节: \(item.downloadedBytes)",
            "预期字节: \(item.totalBytes)",
            "重试次数: \(item.retries ?? 0)",
            "最后进度: \(item.lastProgressAt?.description ?? "无")",
            "错误: \(item.errorMessage ?? "无")"
        ].joined(separator: "\n")
    }

    @MainActor private func retry(_ item: DownloadItem) {
        if SegmentedDownloader.shared.contains(id: item.id) {
            SegmentedDownloader.shared.retry(id: item.id)
        } else if item.source == .direct {
            BackgroundDownloader.shared.retryExisting(id: item.id)
        } else {
            display(DownloadError.unsupportedLink("网页下载链接可能包含临时授权，请返回浏览器重新点击下载。"))
        }
    }

    @MainActor private func delete(_ item: DownloadItem, file: Bool) {
        do {
            try DownloadCoordinator.shared.remove(id: item.id, deleteFile: file)
            dismiss()
        } catch { display(error) }
    }
    private func display(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

private struct DownloadSettingsView: View {
    @ObservedObject private var store = DownloadStore.shared
    @ObservedObject private var incomingRouter = IncomingLinkRouter.shared
    @AppStorage("bgdl.downloadMode") private var downloadMode = "smart"
    @AppStorage("bgdl.notifyDownloads") private var notifyDownloads = false
    @AppStorage("bgdl.webAppearanceMode") private var webAppearanceMode = "auto"
    @State private var showHistoryClear = false

    private var localStorageBytes: Int64 {
        let paths = (try? FileManager.default.contentsOfDirectory(at: DownloadStore.downloadFolder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        return paths.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    var body: some View {
        Form {
            Section {
                Label("BackgroundDL 2.0", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                LabeledContent("已保存文件总大小", value: localStorageBytes.readableSize)
                LabeledContent("已完成任务", value: "\(store.completedCount)")
                LabeledContent("正在下载", value: "\(store.runningCount)")
            }
            Section("下载引擎") {
                Picker("下载模式", selection: $downloadMode) {
                    ForEach(DownloadMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                Toggle("下载完成和失败通知", isOn: $notifyDownloads)
                    .onChange(of: notifyDownloads) { _, enabled in
                        if enabled { DownloadNotifications.requestPermission() }
                    }
                Text("智能/极速模式仅对支持 Range 的 HTTPS 直链尝试多连接。后台传输仍由 iOS 调度，不能保证持续满速。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("浏览器") {
                Picker("网页外观", selection: $webAppearanceMode) {
                    Text("智能深色").tag("auto")
                    Text("始终深色").tag("always")
                    Text("网站原样").tag("off")
                }
                Button("清除浏览历史", role: .destructive) { showHistoryClear = true }
                Text("清除历史不会清理浏览器 Cookie 或取消正在进行的下载。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("拖放诊断") {
                Text("拖到主屏幕图标后若 App 打开但网页没有打开，请复制下方记录。记录只包含事件类型和网站域名，不包含完整 URL 或授权参数。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(Array(incomingRouter.events.prefix(10).enumerated()), id: \.offset) { _, event in
                    Text(event).font(.caption2.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("复制诊断") {
                        UIPasteboard.general.string = incomingRouter.events.joined(separator: "\n")
                    }
                    Spacer()
                    Button("清空") { incomingRouter.clear() }
                        .foregroundStyle(.secondary)
                }
            }
            Section("隐私与诊断") {
                Text("任务详情支持分享脱敏诊断报告，不包含完整签名链接、密码或 Cookie。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("下载文件仅保存在本机的「文件 → 在我的 iPhone 上 → 后台下载 → Downloads」。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .confirmationDialog("清除浏览历史？", isPresented: $showHistoryClear) {
            Button("清除历史", role: .destructive) { BrowserLibrary.shared.clearHistory() }
        }
    }
}
