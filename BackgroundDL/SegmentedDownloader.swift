import Foundation

private struct SegmentMarker: Codable {
    let id: UUID
    let index: Int
    var encoded: String { ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString() }
    static func decode(_ text: String?) -> Self? {
        guard let text, let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

private struct SegmentManifest: Codable {
    let id: UUID
    let originalURL: String
    let filename: String
    let total: Int64
    let validator: String?
    let ranges: [ByteRange]
    var assembledBytes: Int64 = 0
    var nextAssemblyIndex: Int = 0
}

@MainActor
final class SegmentedDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = SegmentedDownloader()
    static let identifier = "com.example.backgrounddl.segments"
    private var isAssembling = Set<UUID>()
    private var inFlightProgress: [UUID: [Int: Int64]] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() { super.init() }

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Segments", isDirectory: true)
    }
    nonisolated static func directory(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString) }
    nonisolated static func part(_ id: UUID, index: Int) -> URL { directory(id).appendingPathComponent("part-\(index)") }
    private static func manifestURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("manifest.json") }

    private func manifest(for id: UUID) -> SegmentManifest? {
        guard let data = try? Data(contentsOf: Self.manifestURL(id)) else { return nil }
        return try? JSONDecoder().decode(SegmentManifest.self, from: data)
    }
    private func save(_ manifest: SegmentManifest) throws {
        let dir = Self.directory(manifest.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: Self.manifestURL(manifest.id), options: .atomic)
    }
    private func allIDs() -> [UUID] {
        let paths = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        return paths.compactMap(UUID.init(uuidString:)).filter { manifest(for: $0) != nil }
    }
    func contains(id: UUID) -> Bool { manifest(for: id) != nil }
    func activeIDs() -> Set<UUID> { Set(allIDs()) }

    // Caller verifies HEAD + actual one-byte 206 first. No segmentation without it.
    func start(request: URLRequest, originalURL: String, name: String,
               probe: RangeProbeResult, segments: Int) throws {
        let ranges = ByteRange.plan(total: probe.size, count: segments)
        guard ranges.count == segments else { throw NSError(domain: "BackgroundDL", code: 31) }
        let stored = DownloadStore.shared
        let id = UUID()
        let resolvedName = stored.uniqueFilename(preferred: name)
        let manifest = SegmentManifest(id: id, originalURL: originalURL,
                                       filename: resolvedName, total: probe.size,
                                       validator: probe.validator, ranges: ranges)
        try save(manifest)
        let item = DownloadItem(id: id, originalURL: originalURL, filename: resolvedName,
                                source: .direct, status: .running, downloadedBytes: 0,
                                totalBytes: probe.size, errorMessage: nil, savedFilename: nil,
                                createdAt: Date(), resumeDataBase64: nil)
        stored.add(item)
        for index in ranges.indices { schedulePart(manifest, index: index, original: request) }
    }

    private func schedulePart(_ manifest: SegmentManifest, index: Int, original: URLRequest) {
        let part = manifest.ranges[index]
        var request = original
        request.httpMethod = "GET"
        request.setValue("bytes=\(part.start)-\(part.end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator = manifest.validator {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = SegmentMarker(id: manifest.id, index: index).encoded
        task.resume()
    }

    func reconnect() {
        session.getAllTasks { tasks in
            Task { @MainActor in
                let active = Set(tasks.filter { $0.state == .running || $0.state == .suspended }
                    .compactMap { SegmentMarker.decode($0.taskDescription) }
                    .map { "\($0.id.uuidString)/\($0.index)" })
                for id in self.allIDs() {
                    guard let m = self.manifest(for: id) else { continue }
                    guard let record = DownloadStore.shared.items.first(where: { $0.id == id }),
                          record.status != .cancelled, record.status != .completed else {
                        continue
                    }
                    let done = m.ranges.indices.allSatisfy { index in
                        let part = Self.part(id, index: index)
                        return ((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1) == m.ranges[index].length
                            || index < m.nextAssemblyIndex
                    }
                    if done {
                        self.assembleIfReady(id: id)
                        continue
                    }
                    // Re-create only missing chunks when direct URL still works. Saved
                    // segments survive relaunch; never discard completed chunks.
                    if record.status == .running,
                       let url = URL(string: m.originalURL), url.scheme == "https" {
                        for i in m.ranges.indices {
                            let part = Self.part(id, index: i)
                            let exists = ((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1) == m.ranges[i].length
                            if !exists && !active.contains("\(id.uuidString)/\(i)") {
                                self.schedulePart(m, index: i, original: URLRequest(url: url))
                            }
                        }
                    }
                }
            }
        }
    }

    // Retry only unfinished HTTP ranges; retain validated completed chunks.
    func retry(id: UUID) {
        guard manifest(for: id) != nil else { return }
        DownloadStore.shared.update(id, status: .running)
        reconnect()
    }

    func changeState(id: UUID, action: DownloadAction) {
        guard contains(id: id) else { return }
        session.getAllTasks { tasks in
            Task { @MainActor in
                let matching = tasks.filter { SegmentMarker.decode($0.taskDescription)?.id == id }
                switch action {
                case .pause:
                    matching.forEach { $0.suspend() }
                    DownloadStore.shared.update(id, status: .paused, message: "分段暂停：重启后未完成分段可能需要重下。")
                case .resume:
                    matching.forEach { $0.resume() }
                    DownloadStore.shared.update(id, status: .running)
                    self.reconnect()
                case .cancel:
                    matching.forEach { $0.cancel() }
                    DownloadStore.shared.update(id, status: .cancelled)
                    // Keep partially downloaded ranges so user can inspect; delete only
                    // when explicitly removing the record.
                }
            }
        }
    }

    func remove(id: UUID) {
        session.getAllTasks { tasks in
            for task in tasks where SegmentMarker.decode(task.taskDescription)?.id == id { task.cancel() }
        }
        try? FileManager.default.removeItem(at: Self.directory(id))
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let marker = SegmentMarker.decode(downloadTask.taskDescription) else { return }
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 206 {
            downloadTask.cancel()
            Task { @MainActor in self.fail(marker.id, "服务器未返回分段数据（HTTP \(response.statusCode)），可切回稳定模式。") }
            return
        }
        Task { @MainActor in
            self.inFlightProgress[marker.id, default: [:]][marker.index] = totalBytesWritten
            self.report(marker.id)
        }
    }

    private func report(_ id: UUID) {
        guard let manifest = manifest(for: id) else { return }
        let complete = manifest.ranges.indices.reduce(Int64(0)) { sum, i in
            let part = Self.part(id, index: i)
            let bytes = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let inFlight = inFlightProgress[id]?[i] ?? 0
            return sum + min(manifest.ranges[i].length, max(bytes, inFlight))
        }
        DownloadStore.shared.progress(id, written: complete, expected: manifest.total)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let marker = SegmentMarker.decode(downloadTask.taskDescription) else { return }
        // Download temp location is invalid once this delegate call returns.
        let target = Self.part(marker.id, index: marker.index)
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == 206,
                  let header = response.value(forHTTPHeaderField: "Content-Range") else {
                throw NSError(domain: "BackgroundDL", code: 41,
                              userInfo: [NSLocalizedDescriptionKey: "服务器没有返回正确的 206/Content-Range。"])
            }
            try FileManager.default.createDirectory(at: Self.directory(marker.id), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            let bytes = Int64((try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            Task { @MainActor in self.validateAndComplete(marker, header: header, actual: bytes) }
        } catch {
            Task { @MainActor in self.fail(marker.id, error.localizedDescription) }
        }
    }

    private func validateAndComplete(_ marker: SegmentMarker, header: String, actual: Int64) {
        guard let manifest = manifest(for: marker.id),
              manifest.ranges.indices.contains(marker.index) else { return }
        let part = manifest.ranges[marker.index]
        guard let contentRange = ContentRange(header),
              contentRange.matches(part, totalBytes: manifest.total), actual == part.length else {
            try? FileManager.default.removeItem(at: Self.part(marker.id, index: marker.index))
            fail(marker.id, "分段长度或 Content-Range 不匹配，已拒绝该分段，避免文件损坏。")
            return
        }
        inFlightProgress[marker.id]?[marker.index] = nil
        report(marker.id)
        assembleIfReady(id: marker.id)
    }

    private func assembleIfReady(id: UUID) {
        guard !isAssembling.contains(id), let manifest = manifest(for: id),
              manifest.ranges.indices.allSatisfy({ i in
                i < manifest.nextAssemblyIndex ||
                    ((try? Self.part(id, index: i).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1) == manifest.ranges[i].length
              }) else { return }
        isAssembling.insert(id)
        Task.detached(priority: .utility) {
            do {
                try Self.assemble(id: id)
                await MainActor.run {
                    self.isAssembling.remove(id)
                    do {
                        try DownloadStore.shared.finalizeStagedDownload(id: id, preferredName: nil)
                        try? FileManager.default.removeItem(at: Self.directory(id))
                        DownloadNotifications.deliver(title: "下载完成", detail: manifest.filename)
                    } catch { self.fail(id, "分段合并失败：\(error.localizedDescription)") }
                }
            } catch {
                await MainActor.run {
                    self.isAssembling.remove(id)
                    self.fail(id, "分段合并失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // Crash-safe bounded-memory join. Completed chunks are deleted only after
    // their output offset has been journaled. A partial append is truncated on retry.
    nonisolated private static func assemble(id: UUID) throws {
        let dir = directory(id)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let bytes = try? Data(contentsOf: manifestURL),
              var m = try? JSONDecoder().decode(SegmentManifest.self, from: bytes) else {
            throw NSError(domain: "BackgroundDL", code: 50,
                          userInfo: [NSLocalizedDescriptionKey: "分段清单损坏。"])
        }
        let temp = dir.appendingPathComponent("assembled.tmp")
        if !FileManager.default.fileExists(atPath: temp.path) {
            _ = FileManager.default.createFile(atPath: temp.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        try output.truncate(atOffset: UInt64(m.assembledBytes))
        try output.seek(toOffset: UInt64(m.assembledBytes))
        for i in m.nextAssemblyIndex..<m.ranges.count {
            let path = part(id, index: i)
            let input = try FileHandle(forReadingFrom: path)
            var written: Int64 = 0
            do {
                while true {
                    let bytes = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if bytes.isEmpty { break }
                    try output.write(contentsOf: bytes)
                    written += Int64(bytes.count)
                }
            } catch { try? input.close(); throw error }
            try input.close()
            guard written == m.ranges[i].length else {
                throw NSError(domain: "BackgroundDL", code: 51,
                     userInfo: [NSLocalizedDescriptionKey: "第 \(i) 段长度校验失败。"])
            }
            try output.synchronize()
            m.assembledBytes += written
            m.nextAssemblyIndex = i + 1
            try JSONEncoder().encode(m).write(to: manifestURL, options: .atomic)
            try FileManager.default.removeItem(at: path)
        }
        guard m.assembledBytes == m.total else {
            throw NSError(domain: "BackgroundDL", code: 52,
                  userInfo: [NSLocalizedDescriptionKey: "最终文件长度校验失败。"])
        }
        try FileManager.default.createDirectory(at: DownloadStore.stagingFolder, withIntermediateDirectories: true)
        let staged = DownloadStore.stagingFolder.appendingPathComponent(id.uuidString + ".stage")
        if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
        try FileManager.default.moveItem(at: temp, to: staged)
    }

    private func fail(_ id: UUID, _ reason: String) {
        guard let item = DownloadStore.shared.items.first(where: { $0.id == id }),
              item.status != .cancelled && item.status != .completed else { return }
        DownloadStore.shared.update(id, status: .failed, message: reason)
        session.getAllTasks { tasks in
            for task in tasks where SegmentMarker.decode(task.taskDescription)?.id == id { task.cancel() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, let marker = SegmentMarker.decode(task.taskDescription) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in self.fail(marker.id, "分段网络错误：\(error.localizedDescription)") }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let callback = DownloaderAppDelegate.segmentCompletionHandler
            DownloaderAppDelegate.segmentCompletionHandler = nil
            callback?()
        }
    }
}
