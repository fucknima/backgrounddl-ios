import SwiftUI
import QuickLook
import Combine
import UIKit
import UniformTypeIdentifiers

enum AppTheme {
    static let accent = Color.cyan
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let border = Color.primary.opacity(0.06)
    static let pagePadding: CGFloat = 18
    static let cardRadius: CGFloat = 20
}

private enum MainTab: Hashable {
    case browser, downloads, settings
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .browser
    @StateObject private var browserState = BrowserState()
    @State private var keyboardVisible = false
    @State private var browserBarHidden = false
    @State private var sharedURL: URL?
    @State private var incomingLinkRevision = UUID()
    @ObservedObject private var incomingRouter = IncomingLinkRouter.shared
    @State private var lastConsumedRevision: UUID?
    @State private var isDropTargeted = false
    @State private var linkError = ""
    @State private var showLinkError = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    BrowserView(state: browserState,
                                sharedURL: sharedURL,
                                openDownloads: { selectedTab = .downloads },
                                openSettings: { selectedTab = .settings },
                                onScrollHideChange: { hidden in
                                    withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                                        browserBarHidden = hidden
                                    }
                                },
                                incomingLinkRevision: incomingLinkRevision,
                                acceptDroppedProviders: { providers in importDrop(providers) })
                }
                    .tabItem { Label("浏览器", systemImage: "safari") }
                    .tag(MainTab.browser)
                    .toolbar(.hidden, for: .tabBar)
                NavigationStack { DownloadListView() }
                    .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
                    .tag(MainTab.downloads)
                    .toolbar(.hidden, for: .tabBar)
                NavigationStack { DownloadSettingsView() }
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(MainTab.settings)
                    .toolbar(.hidden, for: .tabBar)
            }
            .tint(.cyan)
            .toolbar(.hidden, for: .tabBar)
            .ignoresSafeArea(.container, edges: .bottom)

            if !keyboardVisible && !browserBarHidden {
                AppBottomBar(selectedTab: $selectedTab,
                             browser: browserState,
                             openDownloads: { selectedTab = .downloads })
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
        // One interaction on the root view accepts a link from every tab. A
        // SwiftUI drop modifier on the TabView, a List or a Form never sees
        // the drag because their scroll views own the hit testing.
        .background(
            RootDropInstaller(accept: { importDrop($0) }, setTargeted: { isDropTargeted = $0 })
                .frame(width: 1, height: 1)
        )
        .overlay {
            if isDropTargeted {
                ZStack {
                    Color.black.opacity(0.22).ignoresSafeArea()
                    VStack(spacing: 10) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 34, weight: .semibold))
                        Text("松手打开链接")
                            .font(.headline)
                        Text("将在浏览器中打开")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.15))
                    }
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
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
        .onChange(of: selectedTab) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) { browserBarHidden = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = false }
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


private struct AppBottomBar: View {
    @Binding var selectedTab: MainTab
    @ObservedObject var browser: BrowserState
    let openDownloads: () -> Void
    @Namespace private var selectionPill

    var body: some View {
        ZStack {
            browserControls
                .opacity(selectedTab == .browser ? 1 : 0)
                .scaleEffect(selectedTab == .browser ? 1 : 0.96)
                .allowsHitTesting(selectedTab == .browser)
            tabControls
                .opacity(selectedTab == .browser ? 0 : 1)
                .scaleEffect(selectedTab == .browser ? 0.96 : 1)
                .allowsHitTesting(selectedTab != .browser)
        }
        .frame(height: 58)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(AppTheme.border)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: selectedTab)
    }

    private var browserControls: some View {
        HStack(spacing: 0) {
            control("chevron.left", enabled: browser.canGoBack) { browser.webView?.goBack() }
            control("chevron.right", enabled: browser.canGoForward) { browser.webView?.goForward() }
            control("house", enabled: true) { browser.goHome() }
            control("arrow.clockwise", enabled: browser.webView?.url != nil) { browser.webView?.reload() }
            control("arrow.down.circle", enabled: true) { openDownloads() }
        }
        .padding(.horizontal, 8)
    }

    private var tabControls: some View {
        HStack(spacing: 0) {
            tabButton(.browser, "浏览器", "safari")
            tabButton(.downloads, "下载", "arrow.down.circle.fill")
            tabButton(.settings, "设置", "gearshape.fill")
        }
        .padding(.horizontal, 8)
    }

    private func control(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
    }

    private func tabButton(_ tab: MainTab, _ title: String, _ icon: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(selectedTab == tab ? AppTheme.accent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background {
                if selectedTab == tab {
                    Capsule()
                        .fill(Color.primary.opacity(0.07))
                        .matchedGeometryEffect(id: "selectedTabPill", in: selectionPill)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 12)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A drop target installed on the root controller view. It is an ancestor of
/// every tab, so the settings form and the downloads list are covered without
/// fighting their scroll views for the drag session.
private struct RootDropInstaller: UIViewRepresentable {
    let accept: ([NSItemProvider]) -> Bool
    let setTargeted: (Bool) -> Void

    func makeUIView(context: Context) -> RootDropInstallerView {
        let view = RootDropInstallerView()
        view.accept = accept
        view.setTargeted = setTargeted
        return view
    }

    func updateUIView(_ view: RootDropInstallerView, context: Context) {
        view.accept = accept
        view.setTargeted = setTargeted
    }

    static func dismantleUIView(_ view: RootDropInstallerView, coordinator: ()) {
        view.uninstall()
    }
}

private final class RootDropInstallerView: UIView, UIDropInteractionDelegate {
    var accept: (([NSItemProvider]) -> Bool)?
    var setTargeted: ((Bool) -> Void)?
    private var interaction: UIDropInteraction?
    private weak var hostView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else {
            uninstall()
            return
        }
        // The window itself is not a drop host; its root view is.
        let host = window.rootViewController?.view ?? window
        guard hostView !== host else { return }
        uninstall()
        let interaction = UIDropInteraction(delegate: self)
        host.addInteraction(interaction)
        self.interaction = interaction
        hostView = host
    }

    func uninstall() {
        if let interaction {
            hostView?.removeInteraction(interaction)
        }
        interaction = nil
        hostView = nil
        setTargeted?(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [
            UTType.url.identifier,
            UTType.fileURL.identifier,
            UTType.plainText.identifier
        ])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        setTargeted?(true)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        setTargeted?(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        setTargeted?(false)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        setTargeted?(false)
        _ = accept?(session.items.map { $0.itemProvider })
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
            statsHeader
            if visibleItems.isEmpty {
                emptyState
            } else {
                NativeDownloadList(
                    items: visibleItems,
                    pause: { DownloadCoordinator.shared.changeState(id: $0, action: .pause) },
                    resume: { DownloadCoordinator.shared.changeState(id: $0, action: .resume) },
                    cancel: { DownloadCoordinator.shared.changeState(id: $0, action: .cancel) },
                    retry: { id in
                        guard let item = store.items.first(where: { $0.id == id }) else { return }
                        retry(item)
                    },
                    remove: { id, deleteFile in deleteImmediately(id: id, deleteFile: deleteFile) },
                    openDetails: { selectedDetail = DetailSelection(id: $0) },
                    rename: { id, name in try store.renameCompleted(id: id, to: name) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.pageBackground)
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

    private var statsHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                statPill("进行中", "\(store.runningCount)", icon: "arrow.down", tint: AppTheme.accent)
                statPill("已完成", "\(store.completedCount)", icon: "checkmark", tint: .green)
                statPill("总速度", store.aggregateSpeedLabel == "--" ? "—" : store.aggregateSpeedLabel,
                         icon: "speedometer", tint: .orange)
            }
            Picker("状态", selection: $filter) {
                ForEach(DownloadFilter.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("downloadFilter")
        }
        .padding(14)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AppTheme.border)
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func statPill(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(AppTheme.accent)
            Text(searchText.isEmpty ? (filter == .all ? "暂无下载" : "没有相关任务") : "没有匹配的下载")
                .font(.headline)
            Text(searchText.isEmpty ? "从浏览器打开链接，或拖入一个 HTTPS 直链。" : "试试其他文件名。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showDirectInput = true
            } label: {
                Label("添加直链", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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

private struct NativeDownloadList: UIViewControllerRepresentable {
    let items: [DownloadItem]
    let pause: (UUID) -> Void
    let resume: (UUID) -> Void
    let cancel: (UUID) -> Void
    let retry: (UUID) -> Void
    let remove: (UUID, Bool) -> Void
    let openDetails: (UUID) -> Void
    let rename: (UUID, String) throws -> Void

    func makeUIViewController(context: Context) -> DownloadTableController {
        let controller = DownloadTableController()
        apply(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: DownloadTableController, context: Context) {
        apply(to: controller)
    }

    private func apply(to controller: DownloadTableController) {
        controller.pause = pause
        controller.resume = resume
        controller.cancel = cancel
        controller.retry = retry
        controller.remove = remove
        controller.openDetails = openDetails
        controller.rename = rename
        controller.apply(items: items)
    }
}

private final class DownloadTableController: UITableViewController {
    var pause: (UUID) -> Void = { _ in }
    var resume: (UUID) -> Void = { _ in }
    var cancel: (UUID) -> Void = { _ in }
    var retry: (UUID) -> Void = { _ in }
    var remove: (UUID, Bool) -> Void = { _, _ in }
    var openDetails: (UUID) -> Void = { _ in }
    var rename: (UUID, String) throws -> Void = { _, _ in }

    private var items: [DownloadItem] = []
    private var lastIDs: [UUID] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 96, right: 0)
        tableView.showsVerticalScrollIndicator = false
    }

    func apply(items newItems: [DownloadItem]) {
        items = newItems
        let ids = newItems.map(\.id)
        guard ids != lastIDs else { return }
        lastIDs = ids
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        let id = items[indexPath.row].id
        let pause = self.pause, resume = self.resume, cancel = self.cancel
        let retry = self.retry, remove = self.remove, openDetails = self.openDetails
        let rename = self.rename
        cell.contentConfiguration = UIHostingConfiguration {
            LiveDownloadRow(id: id,
                            pause: pause,
                            resume: resume,
                            cancel: cancel,
                            retry: retry,
                            remove: remove,
                            openDetails: openDetails,
                            rename: rename)
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.vertical, 5)
        }
        .margins(.all, 0)
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = items[indexPath.row]
        let action = UIContextualAction(style: .destructive,
                                        title: item.status == .completed ? "删除" : "移除") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.remove(item.id, item.status == .completed)
            completion(true)
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }
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
        HStack(alignment: .center, spacing: 13) {
            statusBadge
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    if item.status == .running || item.status == .paused {
                        Text(progressText)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(item.status == .failed ? .red : .secondary)
                    .lineLimit(1)
                if item.status == .running || item.status == .paused {
                    ProgressView(value: item.fraction ?? 0)
                        .tint(AppTheme.accent)
                        .frame(height: 4)
                    HStack(spacing: 6) {
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
                }
            }
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("管理 \(item.filename)")
        }
        .padding(14)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.border)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: openDetails)
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
        .alert("重命名文件", isPresented: $showRename) {
            TextField("文件名", text: $newName)
            Button("保存") { do { try rename(newName) } catch { report(error) } }
            Button("取消", role: .cancel) { }
        }
        .quickLookPreview($previewURL)
        .alert("操作失败", isPresented: $showError) { Button("确定", role: .cancel) {} } message: { Text(errorText) }
    }

    private var progressText: String {
        guard let fraction = item.fraction else { return "" }
        return "\(Int(fraction * 100))%"
    }

    private var secondaryLine: String {
        let host = URL(string: item.originalURL)?.host ?? item.sourceLabel
        switch item.status {
        case .running:
            return host
        case .paused:
            return "已暂停 · \(host)"
        case .completed:
            let date = item.completedAt.map {
                $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
            } ?? "时间未知"
            return "已完成 · \(item.downloadedBytes.readableSize) · \(date)"
        case .failed:
            return item.errorMessage ?? "下载失败"
        case .cancelled:
            return "已取消 · \(host)"
        }
    }

    private var statusBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(statusTint.opacity(0.14))
                .frame(width: 44, height: 44)
            Image(systemName: statusSymbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(statusTint)
        }
    }

    private var statusTint: Color {
        switch item.status {
        case .running: return AppTheme.accent
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var statusSymbol: String {
        switch item.status {
        case .running: return "arrow.down"
        case .paused: return "pause.fill"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        }
    }

    private func report(_ error: Error) { errorText = error.localizedDescription; showError = true }
}

private struct LiveDownloadRow: View {
    @ObservedObject private var store = DownloadStore.shared
    let id: UUID
    let pause: (UUID) -> Void
    let resume: (UUID) -> Void
    let cancel: (UUID) -> Void
    let retry: (UUID) -> Void
    let remove: (UUID, Bool) -> Void
    let openDetails: (UUID) -> Void
    let rename: (UUID, String) throws -> Void

    var body: some View {
        if let item = store.items.first(where: { $0.id == id }) {
            CompactDownloadRow(item: item,
                               fileURL: store.fileURL(for: item),
                               pause: { pause(id) },
                               resume: { resume(id) },
                               cancel: { cancel(id) },
                               retry: { retry(id) },
                               remove: { deleteFile in remove(id, deleteFile) },
                               openDetails: { openDetails(id) },
                               rename: { name in try rename(id, name) })
        }
    }
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
        ScrollView {
            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("后台下载").font(.headline)
                            Text("版本 \(appVersion)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Divider()
                    HStack(spacing: 0) {
                        statCell("已保存", localStorageBytes.readableSize)
                        Divider().frame(height: 36)
                        statCell("已完成", "\(store.completedCount)")
                        Divider().frame(height: 36)
                        statCell("下载中", "\(store.runningCount)")
                    }
                }
                .padding(16)
                .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                settingsCard("下载引擎") {
                    HStack {
                        Text("下载模式")
                        Spacer(minLength: 8)
                        Picker("下载模式", selection: $downloadMode) {
                            ForEach(DownloadMode.allCases) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(.cyan)
                    }
                    Toggle("下载完成和失败通知", isOn: $notifyDownloads)
                        .tint(.cyan)
                        .onChange(of: notifyDownloads) { _, enabled in
                            if enabled { DownloadNotifications.requestPermission() }
                        }
                    footnote("智能/极速模式仅对支持 Range 的 HTTPS 直链尝试多连接。后台传输仍由 iOS 调度，不能保证持续满速。")
                }

                settingsCard("浏览器") {
                    HStack {
                        Text("网页外观")
                        Spacer(minLength: 8)
                        Picker("网页外观", selection: $webAppearanceMode) {
                            Text("智能深色").tag("auto")
                            Text("始终深色").tag("always")
                            Text("网站原样").tag("off")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(.cyan)
                    }
                    Button(role: .destructive) {
                        showHistoryClear = true
                    } label: {
                        Text("清除浏览历史")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    footnote("清除历史不会清理浏览器 Cookie 或取消正在进行的下载。")
                }

                settingsCard("隐私") {
                    footnote("任务详情支持分享脱敏诊断报告，不包含完整签名链接、密码或 Cookie。")
                    footnote("下载文件仅保存在本机的「文件 → 在我的 iPhone 上 → 后台下载 → Downloads」。")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 96)
        }
        .background(AppTheme.pageBackground)
        .navigationTitle("设置")
        .confirmationDialog("清除浏览历史？", isPresented: $showHistoryClear) {
            Button("清除历史", role: .destructive) { BrowserLibrary.shared.clearHistory() }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
