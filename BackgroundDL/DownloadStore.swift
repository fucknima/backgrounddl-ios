import Foundation
import Combine

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var items: [DownloadItem] = []
    private var lastProgressWrite: [UUID: Date] = [:]
    private var progressSamples: [UUID: ProgressSample] = [:]
    private let databaseURL: URL
    private var lastSavedAt = Date.distantPast

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
        // Recover staging files and finalized-file journal before reconciling OS jobs.
        recoverFinalizedFiles()
        if let stages = try? FileManager.default.contentsOfDirectory(at: Self.stagingFolder,
                                     includingPropertiesForKeys: nil) {
            for stage in stages where stage.pathExtension == "stage" {
                if let id = UUID(uuidString: stage.deletingPathExtension().lastPathComponent),
                   items.contains(where: { $0.id == id && $0.status != .cancelled }) {
                    try? finalizeStagedDownload(id: id, preferredName: nil)
                }
            }
        }
    }

    private func persist(force: Bool = true) {
        // UI callbacks may fire many times per second. Only durable state transitions
        // and periodic snapshots must write the full JSON database.
        if !force && Date().timeIntervalSince(lastSavedAt) < 6 { return }
        guard let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: databaseURL, options: .atomic)
            lastSavedAt = Date()
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: databaseURL.path)
        } catch {
            NSLog("任务列表保存失败: %@", error.localizedDescription)
        }
    }

    private static var resumeFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resumes", isDirectory: true)
    }

    // Reserve a unique filename even when another download with the same name is running.
    func uniqueFilename(preferred: String) -> String {
        let original = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = original.isEmpty ? "下载文件" : original
        var names = Set(items.flatMap { [$0.filename.lowercased(), ($0.savedFilename ?? "").lowercased()] })
        if let files = try? FileManager.default.contentsOfDirectory(atPath: Self.downloadFolder.path) {
            names.formUnion(files.map { $0.lowercased() })
        }
        if !names.contains(safe.lowercased()) { return safe }
        let ext = URL(fileURLWithPath: safe).pathExtension
        let base = ext.isEmpty ? safe : String(safe.dropLast(ext.count + 1))
        for n in 1...100000 {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !names.contains(candidate.lowercased()) { return candidate }
        }
        return UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
    }

    nonisolated static var stagingFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Staging", isDirectory: true)
    }

    // Staged files survive termination. A single complete, verified file is moved
    // into Documents; never overwrite existing downloads.
    func finalizeStagedDownload(id: UUID, preferredName: String?) throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let staged = Self.stagingFolder.appendingPathComponent(id.uuidString + ".stage")
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        let stagedSize = Int64((try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard stagedSize > 0 else { throw NSError(domain: "BackgroundDL", code: 1,
           userInfo: [NSLocalizedDescriptionKey: "服务器没有返回有效文件数据。"] ) }
        // expected byte count can be -1 (unknown) and may also be stale from
        // before a server-side resumption. Only reject a clear short file.
        if item.totalBytes > 0 && stagedSize < item.totalBytes {
            throw NSError(domain: "BackgroundDL", code: 2,
               userInfo: [NSLocalizedDescriptionKey: "文件长度不足：收到 \(stagedSize)，预期 \(item.totalBytes)。"])
        }
        try FileManager.default.createDirectory(at: Self.downloadFolder, withIntermediateDirectories: true)
        var name = item.filename
        if let preferredName, !preferredName.isEmpty,
           preferredName != "download", preferredName != "uc" {
            let sanitized = preferredName.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r"))
                 .joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
            if !sanitized.isEmpty && !item.filename.contains(" (") { name = sanitized }
        }
        name = uniqueFilenameForFinalFile(name, id: id)
        let destination = Self.downloadFolder.appendingPathComponent(name)
        beginFinalization(id: id, filename: name)
        try FileManager.default.moveItem(at: staged, to: destination)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].totalBytes = stagedSize
            items[index].downloadedBytes = stagedSize
        }
        markCompleted(id: id, filename: name)
    }

    private func uniqueFilenameForFinalFile(_ proposed: String, id: UUID) -> String {
        let path = Self.downloadFolder
        let ext = URL(fileURLWithPath: proposed).pathExtension
        let base = ext.isEmpty ? proposed : String(proposed.dropLast(ext.count + 1))
        var candidate = proposed
        var index = 1
        // Other jobs can finish concurrently, but this method is MainActor isolated.
        while FileManager.default.fileExists(atPath: path.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            index += 1
        }
        return candidate
    }

    // A tiny journal closes the crash window between moveItem and marking completed.
    private static var finalizationJournalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("finalizations.json")
    }
    private struct Finalization: Codable { let id: UUID; let filename: String }

    func beginFinalization(id: UUID, filename: String) {
        var journal = finalizationJournal()
        journal.removeAll { $0.id == id }
        journal.append(Finalization(id: id, filename: filename))
        writeJournal(journal)
    }
    private func finalizationJournal() -> [Finalization] {
        guard let data = try? Data(contentsOf: Self.finalizationJournalURL) else { return [] }
        return (try? JSONDecoder().decode([Finalization].self, from: data)) ?? []
    }
    private func writeJournal(_ entries: [Finalization]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.finalizationJournalURL, options: .atomic)
    }
    private func recoverFinalizedFiles() {
        let journal = finalizationJournal()
        for entry in journal {
            guard let index = items.firstIndex(where: { $0.id == entry.id }) else { continue }
            let url = Self.downloadFolder.appendingPathComponent(entry.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                items[index].status = .completed
                items[index].filename = entry.filename
                items[index].savedFilename = entry.filename
                items[index].errorMessage = nil
                items[index].speedBytesPerSecond = nil
                items[index].etaSeconds = nil
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    items[index].downloadedBytes = Int64(size)
                    items[index].totalBytes = Int64(size)
                }
            }
        }
        if !journal.isEmpty { persist(); writeJournal([]) }
    }

    func markCompleted(id: UUID, filename: String) {
        update(id, status: .completed, savedFilename: filename)
        writeJournal(finalizationJournal().filter { $0.id != id })
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
        if status == .running || status == .completed || status == .cancelled {
            items[index].nextRetryAt = nil
        }
        if let savedFilename {
            items[index].savedFilename = savedFilename
            items[index].filename = savedFilename
        }
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
        if status == .completed || status == .cancelled {
            setResumeData(id, data: nil)
        }
        if status == .completed || status == .cancelled || status == .failed {
            progressSamples[id] = nil
        }
        persist()
        DownloadActivityManager.shared.refresh(items, force: true)
    }

    func scheduleRetry(id: UUID, count: Int, after delay: TimeInterval) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].retries = count
        items[index].nextRetryAt = Date().addingTimeInterval(delay)
        items[index].status = .failed
        items[index].errorMessage = "连接中断，\(Int(delay)) 秒后自动重试（\(count)/3）"
        persist()
    }

    func setResumeData(_ id: UUID, data: Data?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let folder = Self.resumeFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id.uuidString).resume")
        if let data {
            do {
                try data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                items[index].resumeFileName = file.lastPathComponent
                items[index].resumeDataBase64 = nil
            } catch {
                NSLog("保存断点失败: %@", error.localizedDescription)
            }
        } else {
            try? FileManager.default.removeItem(at: file)
            items[index].resumeFileName = nil
            items[index].resumeDataBase64 = nil
        }
        persist()
    }

    func resumeData(for id: UUID) -> Data? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        if let fileName = item.resumeFileName {
            return try? Data(contentsOf: Self.resumeFolder.appendingPathComponent(fileName))
        }
        return item.resumeDataBase64.flatMap(Data.init(base64Encoded:))
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
        items[index].lastProgressAt = now
        lastProgressWrite[id] = now
        persist(force: false)
        DownloadActivityManager.shared.refresh(items)
    }

    func reconcile(activeIDs: Set<UUID>, pausedIDs: Set<UUID>) {
        var changed = false
        for i in items.indices {
            if items[i].status == .running || items[i].status == .paused {
                if !activeIDs.contains(items[i].id) {
                    if items[i].status == .running {
                        let canResume = items[i].resumeFileName != nil || items[i].resumeDataBase64 != nil
                        items[i].status = canResume ? .paused : .failed
                        items[i].errorMessage = canResume ? "后台传输已中断，可尝试继续。" : "后台任务已中断，可点击重试。"
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
        try? FileManager.default.removeItem(at: Self.resumeFolder.appendingPathComponent("\(id.uuidString).resume"))
        try? FileManager.default.removeItem(at: Self.stagingFolder.appendingPathComponent("\(id.uuidString).stage"))
        writeJournal(finalizationJournal().filter { $0.id != id })
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
