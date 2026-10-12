import Foundation
import Combine

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var items: [DownloadItem] = []
    private var lastProgressWrite: [UUID: Date] = [:]
    private let databaseURL: URL

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // App 在锁屏状态下被系统唤醒时也需要可以访问任务列表。
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        databaseURL = root.appendingPathComponent("downloads.json")
        if let data = try? Data(contentsOf: databaseURL),
           let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = saved
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: databaseURL, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: databaseURL.path)
        } catch {
            NSLog("任务列表保存失败: %@", error.localizedDescription)
        }
    }

    func add(_ item: DownloadItem) {
        items.insert(item, at: 0)
        persist()
    }

    func update(_ id: UUID, status: DownloadStatus, message: String? = nil, savedFilename: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].errorMessage = message
        if let savedFilename { items[index].savedFilename = savedFilename }
        if status == .completed, items[index].totalBytes > 0 {
            items[index].downloadedBytes = items[index].totalBytes
        }
        persist()
    }

    func progress(_ id: UUID, written: Int64, expected: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status == .running else { return }
        let now = Date()
        if let last = lastProgressWrite[id], now.timeIntervalSince(last) < 0.35,
           !(expected > 0 && written >= expected) { return }
        items[index].downloadedBytes = written
        items[index].totalBytes = expected
        lastProgressWrite[id] = now
        persist()
    }

    func reconcile(activeIDs: Set<UUID>, pausedIDs: Set<UUID>) {
        var changed = false
        for i in items.indices {
            if items[i].status == .running || items[i].status == .paused {
                if !activeIDs.contains(items[i].id) {
                    items[i].status = .failed
                    items[i].errorMessage = "后台任务已中断，可点击重试（将重新下载）。"
                    changed = true
                } else {
                    let status: DownloadStatus = pausedIDs.contains(items[i].id) ? .paused : .running
                    if items[i].status != status {
                        items[i].status = status
                        changed = true
                    }
                }
            }
        }
        if changed { persist() }
    }

    func fileURL(for item: DownloadItem) -> URL? {
        guard item.status == .completed, let name = item.savedFilename else { return nil }
        return Self.downloadFolder.appendingPathComponent(name)
    }

    nonisolated static var downloadFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }
}
