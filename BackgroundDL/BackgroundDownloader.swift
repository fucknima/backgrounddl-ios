import Foundation
import UIKit
import UserNotifications

final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloader()
    static let sessionIdentifier = "com.example.backgrounddl.transfers"

    private lazy var session: URLSession = {
        let settings = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        settings.sessionSendsLaunchEvents = true
        settings.isDiscretionary = false
        settings.allowsCellularAccess = true
        settings.allowsExpensiveNetworkAccess = true
        settings.allowsConstrainedNetworkAccess = true
        settings.waitsForConnectivity = true
        settings.timeoutIntervalForRequest = 120
        settings.timeoutIntervalForResource = 60 * 60 * 24 * 7
        settings.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: settings, delegate: self, delegateQueue: nil)
    }()

    private override init() { super.init() }

    // Tombstones prevent a download-complete callback racing with user deletion
    // from recreating a removed file/record in the Files directory.
    private let removedLock = NSLock()
    private var removedIDs = Set<UUID>()

    private func markRemoved(_ id: UUID) {
        removedLock.lock()
        removedIDs.insert(id)
        removedLock.unlock()
    }

    private func wasRemoved(_ id: UUID) -> Bool {
        removedLock.lock()
        defer { removedLock.unlock() }
        return removedIDs.contains(id)
    }

    @MainActor
    func remove(id: UUID, deleteFile: Bool) throws {
        // Delete the associated local file first; if that fails, keep the task record.
        try DownloadStore.shared.remove(id: id, deleteFile: deleteFile)
        markRemoved(id)
        session.getAllTasks { tasks in
            for task in tasks where TaskMarker.decode(task.taskDescription)?.id == id {
                task.cancel()
            }
        }
    }

    @MainActor
    func enqueue(request: URLRequest, originalURL: String, name: String, source: DownloadSource) {
        let reservedName = DownloadStore.shared.uniqueFilename(preferred: Self.safeFilename(name))
        let item = DownloadItem(
            id: UUID(), originalURL: originalURL, filename: reservedName, source: source,
            status: .running, downloadedBytes: 0, totalBytes: -1,
            errorMessage: nil, savedFilename: nil, createdAt: Date(), resumeDataBase64: nil
        )
        DownloadStore.shared.add(item)
        let task = session.downloadTask(with: request)
        task.taskDescription = TaskMarker(id: item.id, filename: reservedName, source: source).text
        task.resume()
    }

    func reconnect() {
        session.getAllTasks { tasks in
            Task { @MainActor in
                let storedIDs = Set(DownloadStore.shared.items.map(\.id))
                // Cancel orphaned jobs left behind by a previous remove/crash.
                var pairs: [(UUID, Bool)] = []
                for task in tasks {
                    guard let marker = TaskMarker.decode(task.taskDescription) else { continue }
                    if !storedIDs.contains(marker.id) {
                        self.markRemoved(marker.id)
                        task.cancel()
                    } else {
                        pairs.append((marker.id, task.state == .suspended))
                    }
                }
                let active = Set(pairs.map(\.0)).union(SegmentedDownloader.shared.activeIDs())
                let paused = Set(pairs.filter(\.1).map(\.0))
                DownloadStore.shared.reconcile(activeIDs: active, pausedIDs: paused)
                DownloadRetryManager.shared.resumePending()
            }
        }
    }

    func changeState(id: UUID, action: DownloadAction) {
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { TaskMarker.decode($0.taskDescription)?.id == id }) else {
                Task { @MainActor in
                    if action == .resume, let resumeData = DownloadStore.shared.resumeData(for: id) {
                        self.resumeWithResumeData(id: id, data: resumeData)
                    } else {
                        DownloadStore.shared.update(id, status: .failed, message: "找不到原任务，请使用重试。")
                    }
                }
                return
            }
            switch action {
            case .pause:
                if let downloadTask = task as? URLSessionDownloadTask {
                    downloadTask.cancel(byProducingResumeData: { resumeData in
                        Task { @MainActor in
                            DownloadStore.shared.setResumeData(id, data: resumeData)
                            DownloadStore.shared.update(id, status: .paused,
                                message: resumeData == nil ? "此服务器未提供断点数据；继续时可能需要重新下载。" : nil)
                        }
                    })
                } else {
                    task.suspend()
                    Task { @MainActor in
                        DownloadStore.shared.update(id, status: .paused)
                    }
                }
            case .resume:
                Task { @MainActor in
                    if let resumeData = DownloadStore.shared.resumeData(for: id) {
                        self.resumeWithResumeData(id: id, data: resumeData)
                    } else {
                        task.resume()
                        DownloadStore.shared.update(id, status: .running)
                    }
                }
            case .cancel:
                task.cancel()
                Task { @MainActor in
                    DownloadStore.shared.setResumeData(id, data: nil)
                    DownloadStore.shared.update(id, status: .cancelled)
                }
            }
        }
    }

    @MainActor
    private func resumeWithResumeData(id: UUID, data: Data) {
        guard let item = DownloadStore.shared.items.first(where: { $0.id == id }) else { return }
        let task = session.downloadTask(withResumeData: data)
        task.taskDescription = TaskMarker(id: item.id, filename: item.filename, source: item.source).text
        task.resume()
        DownloadStore.shared.update(id, status: .running)
    }

    @MainActor
    func retryExisting(id: UUID) {
        guard let item = DownloadStore.shared.items.first(where: { $0.id == id }),
              item.status != .cancelled, item.status != .completed else { return }
        let task: URLSessionDownloadTask
        if let data = DownloadStore.shared.resumeData(for: id) {
            task = session.downloadTask(withResumeData: data)
        } else if let url = URL(string: item.originalURL), url.scheme == "https" {
            task = session.downloadTask(with: URLRequest(url: url))
        } else {
            DownloadStore.shared.update(id, status: .failed, message: "重试地址无效，请重新下载。")
            return
        }
        task.taskDescription = TaskMarker(id: id, filename: item.filename, source: item.source).text
        task.resume()
        DownloadStore.shared.update(id, status: .running)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let marker = TaskMarker.decode(downloadTask.taskDescription) else { return }
        Task { @MainActor in
            DownloadStore.shared.progress(marker.id, written: totalBytesWritten,
                                          expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let marker = TaskMarker.decode(downloadTask.taskDescription),
              !wasRemoved(marker.id) else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            let code = response.statusCode
            Task { @MainActor in
                let hint = code == 401 ? "登录凭据可能过期，请返回网页重新点下载" :
                           code == 403 ? "没有权限或下载受限" :
                           code == 404 ? "文件不存在或无权访问" : "请检查链接和网络"
                DownloadStore.shared.update(marker.id, status: .failed, message: "HTTP \(code)：\(hint)")
            }
            return
        }
        if let response = downloadTask.response as? HTTPURLResponse,
           let mime = response.mimeType?.lowercased(),
           (mime == "text/html" || mime == "application/xhtml+xml"),
           !(response.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("attachment") {
            Task { @MainActor in
                DownloadStore.shared.update(marker.id, status: .failed,
                    message: "服务器返回网页而不是文件（可能需要登录、确认大文件或链接过期）。")
            }
            return
        }
        // Move out of URLSession's ephemeral path BEFORE returning from delegate.
        // A crash between that move and the DB update can be repaired on next launch.
        do {
            let staging = DownloadStore.stagingFolder
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let target = staging.appendingPathComponent(marker.id.uuidString + ".stage")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            let suggested = downloadTask.response?.suggestedFilename
            Task { @MainActor in
                guard !self.wasRemoved(marker.id),
                      DownloadStore.shared.items.contains(where: { $0.id == marker.id }) else {
                    try? FileManager.default.removeItem(at: target)
                    return
                }
                do {
                    try DownloadStore.shared.finalizeStagedDownload(id: marker.id, preferredName: suggested)
                    DownloadNotifications.deliver(title: "下载完成", detail: marker.filename)
                } catch {
                    DownloadStore.shared.update(marker.id, status: .failed,
                        message: "文件保存/校验失败：\(error.localizedDescription)，临时文件已保留。")
                    DownloadNotifications.deliver(title: "下载保存失败", detail: marker.filename)
                }
            }
        } catch {
            Task { @MainActor in
                DownloadStore.shared.update(marker.id, status: .failed, message: "临时文件保存失败：\(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error, let marker = TaskMarker.decode(task.taskDescription) else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled || wasRemoved(marker.id) { return }
        let resumeData = ns.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
        Task { @MainActor in
            if DownloadRetryManager.shared.schedule(id: marker.id, error: ns, resumeData: resumeData) {
                return
            }
            let existing = DownloadStore.shared.items.first { $0.id == marker.id }
            guard let existing, existing.status != .cancelled,
                  existing.status != .paused, existing.status != .completed,
                  existing.status != .failed else { return }
            if let resumeData {
                DownloadStore.shared.setResumeData(marker.id, data: resumeData)
                DownloadStore.shared.update(marker.id, status: .paused,
                    message: "网络中断，已保留断点；可尝试继续。")
            } else {
                DownloadStore.shared.update(marker.id, status: .failed,
                    message: error.localizedDescription)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        var safer = request
        if response.url?.host?.lowercased() != request.url?.host?.lowercased() {
            safer.setValue(nil, forHTTPHeaderField: "Cookie")
            safer.setValue(nil, forHTTPHeaderField: "Authorization")
            safer.setValue(nil, forHTTPHeaderField: "Referer")
        }
        completionHandler(safer)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = DownloaderAppDelegate.backgroundCompletionHandler
            DownloaderAppDelegate.backgroundCompletionHandler = nil
            handler?()
        }
    }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0\n\r")
        var safe = name.components(separatedBy: invalid).joined(separator: "_")
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.isEmpty || safe == "." || safe == ".." { return "下载文件" }
        return String(safe.prefix(180))
    }
}

enum DownloadAction { case pause, resume, cancel }
