import Foundation
import Combine

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var items: [DownloadItem] = []
    private var lastProgressWrite: [UUID: Date] = [:]
    private var progressSamples: [UUID: ProgressSample] = [:]
    private let databaseURL: URL

    private struct ProgressSample {
        var bytes: Int64
        var date: Date
        var smoothedSpeed: Double?
    }

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        // The first callback establishes a baseline; resumeData can already contain gigabytes.
        progressSamples[item.id] = nil
        persist()
        DownloadActivityManager.shared.refresh(items, force: true)
    }

    func update(_ id: UUID, status: DownloadStatus, message: String? = nil, savedFilename: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].errorMessage = message
        if let savedFilename { items[index].savedFilename = savedFilename }
        if status == .completed, items[index].totalBytes > 0 {
            items[index].downloadedBytes = items[index].totalBytes
        }
        if status != .running {
            items[index].speedBytesPerSecond = nil
            items[index].etaSeconds = nil
            progressSamples[id] = nil
        } else {
            // Do not reuse a speed sample recorded before a pause or process restart.
            items[index].speedBytesPerSecond = nil
            items[index].etaSeconds = nil
            progressSamples[id] = nil
        }
        if status == .completed || status == .running || status == .cancelled || status == .failed {
            items[index].resumeDataBase64 = nil
        }
        if status == .completed || status == .cancelled || status == .failed {
            progressSamples[id] = nil
        }
        persist()
        DownloadActivityManager.shared.refresh(items, force: true)
    }

    func setResumeData(_ id: UUID, data: Data?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].resumeDataBase64 = data?.base64EncodedString()
        persist()
    }

    func resumeData(for id: UUID) -> Data? {
        guard let item = items.first(where: { $0.id == id }),
              let text = item.resumeDataBase64 else { return nil }
        return Data(base64Encoded: text)
    }

    func progress(_ id: UUID, written: Int64, expected: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status == .running else { return }
        let now = Date()

        if var sample = progressSamples[id] {
            let deltaBytes = written - sample.bytes
            let deltaTime = now.timeIntervalSince(sample.date)
            if deltaBytes < 0 {
                // A restarted task may begin from zero; never report a negative speed.
                sample = ProgressSample(bytes: written, date: now, smoothedSpeed: nil)
                items[index].speedBytesPerSecond = nil
                items[index].etaSeconds = nil
            } else if deltaTime >= 0.8 {
                let instant = Double(deltaBytes) / deltaTime
                // EMA smooths bursty download callbacks; a zero delta clears stale speeds.
                let smoothed = sample.smoothedSpeed.map { $0 * 0.55 + instant * 0.45 } ?? instant
                sample.smoothedSpeed = smoothed
                items[index].speedBytesPerSecond = smoothed >= 1 ? smoothed : nil
                if expected > written, smoothed > 1 {
                    items[index].etaSeconds = Double(expected - written) / smoothed
                } else {
                    items[index].etaSeconds = nil
                }
                sample.bytes = written
                sample.date = now
            }
            progressSamples[id] = sample
        } else {
            progressSamples[id] = ProgressSample(bytes: written, date: now, smoothedSpeed: nil)
            items[index].speedBytesPerSecond = nil
            items[index].etaSeconds = nil
        }

        if let last = lastProgressWrite[id], now.timeIntervalSince(last) < 0.35,
           !(expected > 0 && written >= expected) { return }
        items[index].downloadedBytes = written
        items[index].totalBytes = expected
        lastProgressWrite[id] = now
        persist()
        DownloadActivityManager.shared.refresh(items)
    }

    func reconcile(activeIDs: Set<UUID>, pausedIDs: Set<UUID>) {
        var changed = false
        for i in items.indices {
            if items[i].status == .running || items[i].status == .paused {
                if !activeIDs.contains(items[i].id) {
                    if items[i].status == .running {
                        items[i].status = items[i].resumeDataBase64 == nil ? .failed : .paused
                        items[i].errorMessage = items[i].resumeDataBase64 == nil ? "后台任务已中断，可点击重试。" : nil
                        items[i].speedBytesPerSecond = nil
                        items[i].etaSeconds = nil
                        changed = true
                    }
                } else {
                    let status: DownloadStatus = pausedIDs.contains(items[i].id) ? .paused : .running
                    if items[i].status != status {
                        items[i].status = status
                        if status != .running {
                            items[i].speedBytesPerSecond = nil
                            items[i].etaSeconds = nil
                        }
                        changed = true
                    }
                }
            }
        }
        if changed {
            persist()
            DownloadActivityManager.shared.refresh(items, force: true)
        }
    }

    // Remove a record without touching its file unless the user explicitly requests both.
    // A completed file remains available in Files after "remove record".
    func remove(id: UUID, deleteFile: Bool) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        if deleteFile, item.status == .completed, let name = item.savedFilename {
            let folder = Self.downloadFolder.standardizedFileURL
            let file = folder.appendingPathComponent(name, isDirectory: false).standardizedFileURL
            guard file.deletingLastPathComponent() == folder else {
                throw DownloadFileError.invalidFilename
            }
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        items.remove(at: index)
        lastProgressWrite[id] = nil
        progressSamples[id] = nil
        persist()
        DownloadActivityManager.shared.refresh(items, force: true)
    }

    func clearCompleted(deleteFiles: Bool) throws {
        // Stop if a file cannot be deleted, leaving that record visible for retry.
        let ids = items.filter { $0.status == .completed }.map(\.id)
        for id in ids { try remove(id: id, deleteFile: deleteFiles) }
    }

    func renameCompleted(id: UUID, to proposedName: String) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .completed,
              let oldName = items[index].savedFilename else {
            throw DownloadFileError.notCompleted
        }
        var newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != ".", newName != "..",
              !newName.contains("/"), !newName.contains("\\"),
              !newName.contains(":"), !newName.contains("\n"), !newName.contains("\r") else {
            throw DownloadFileError.invalidFilename
        }
        // Keep the old file extension when a new name does not supply one.
        let oldExtension = URL(fileURLWithPath: oldName).pathExtension
        if !oldExtension.isEmpty && URL(fileURLWithPath: newName).pathExtension.isEmpty {
            newName += "." + oldExtension
        }
        if oldName == newName { return }
        let folder = Self.downloadFolder
        let source = folder.appendingPathComponent(oldName)
        let destination = folder.appendingPathComponent(newName)
        guard FileManager.default.fileExists(atPath: source.path) else { throw DownloadFileError.fileMissing }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadFileError.fileExists }
        try FileManager.default.moveItem(at: source, to: destination)
        items[index].savedFilename = newName
        items[index].filename = newName
        persist()
    }

    func fileURL(for item: DownloadItem) -> URL? {
        guard item.status == .completed, let name = item.savedFilename else { return nil }
        return Self.downloadFolder.appendingPathComponent(name)
    }

    var runningCount: Int {
        items.filter { $0.status == .running }.count
    }

    var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }

    var aggregateSpeedLabel: String {
        let total = items.compactMap(\.speedBytesPerSecond).reduce(0, +)
        guard total > 0 else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) + "/s"
    }

    nonisolated static var downloadFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }
}

private enum DownloadFileError: LocalizedError {
    case invalidFilename, notCompleted, fileMissing, fileExists

    var errorDescription: String? {
        switch self {
        case .invalidFilename: return "文件名不合法。"
        case .notCompleted: return "只能重命名已完成的文件。"
        case .fileMissing: return "本地文件不存在，可能已在文件 App 中移动或删除。"
        case .fileExists: return "目标文件名已存在，请换一个名称。"
        }
    }
}
