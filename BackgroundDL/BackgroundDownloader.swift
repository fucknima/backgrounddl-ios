import Foundation
import UIKit

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
        let item = DownloadItem(
            id: UUID(), originalURL: originalURL, filename: name, source: source,
            status: .running, downloadedBytes: 0, totalBytes: -1,
            errorMessage: nil, savedFilename: nil, createdAt: Date(), resumeDataBase64: nil
        )
        DownloadStore.shared.add(item)
        let task = session.downloadTask(with: request)
        task.taskDescription = TaskMarker(id: item.id, filename: name, source: source).text
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
                let active = Set(pairs.map(\.0))
                let paused = Set(pairs.filter(\.1).map(\.0))
                DownloadStore.shared.reconcile(activeIDs: active, pausedIDs: paused)
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
        do {
            let directory = DownloadStore.downloadFolder
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            var candidate = marker.filename
            if let suggested = downloadTask.response?.suggestedFilename, !suggested.isEmpty, suggested != "download" {
                candidate = suggested
            }
            candidate = Self.safeFilename(candidate)
            var destination = directory.appendingPathComponent(candidate)
            let base = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            var n = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                let renamed = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                destination = directory.appendingPathComponent(renamed)
                n += 1
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            Task { @MainActor in
                DownloadStore.shared.update(marker.id, status: .completed, savedFilename: destination.lastPathComponent)
            }
        } catch {
            Task { @MainActor in
                DownloadStore.shared.update(marker.id, status: .failed, message: "保存失败：\(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error, let marker = TaskMarker.decode(task.taskDescription) else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        let resumeData = ns.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
        Task { @MainActor in
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
