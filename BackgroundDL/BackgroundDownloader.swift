import Foundation
import UIKit

final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloader()
    static let sessionIdentifier = "com.example.backgrounddl.transfers"

    // 系统后台传输需要使用 downloadTask（不能用 dataTask）。
    private lazy var session: URLSession = {
        let settings = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        settings.sessionSendsLaunchEvents = true
        settings.isDiscretionary = false  // 尽量尽快开始；iOS 仍可自行调度
        settings.allowsCellularAccess = true
        settings.timeoutIntervalForResource = 60 * 60 * 24 * 7
        return URLSession(configuration: settings, delegate: self, delegateQueue: nil)
    }()

    private override init() { super.init() }

    @MainActor
    func enqueue(request: URLRequest, originalURL: String, name: String, source: DownloadSource) {
        let item = DownloadItem(
            id: UUID(), originalURL: originalURL, filename: name, source: source,
            status: .running, downloadedBytes: 0, totalBytes: -1,
            errorMessage: nil, savedFilename: nil, createdAt: Date()
        )
        DownloadStore.shared.add(item)
        let task = session.downloadTask(with: request)
        task.taskDescription = TaskMarker(id: item.id, filename: name, source: source).text
        task.resume()
    }

    // 恢复后台会话的关联。进程被系统回收时，iOS 可能重新唤醒 App。
    func reconnect() {
        session.getAllTasks { tasks in
            let pairs = tasks.compactMap { task -> (UUID, Bool)? in
                guard let marker = TaskMarker.decode(task.taskDescription) else { return nil }
                return (marker.id, task.state == .suspended)
            }
            let active = Set(pairs.map(\.0))
            let paused = Set(pairs.filter(\.1).map(\.0))
            Task { @MainActor in
                DownloadStore.shared.reconcile(activeIDs: active, pausedIDs: paused)
            }
        }
    }

    func changeState(id: UUID, action: DownloadAction) {
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { TaskMarker.decode($0.taskDescription)?.id == id }) else {
                Task { @MainActor in
                    DownloadStore.shared.update(id, status: .failed, message: "找不到原任务，请使用重试。")
                }
                return
            }
            switch action {
            case .pause:
                task.suspend()
            case .resume:
                task.resume()
            case .cancel:
                task.cancel()
            }
            Task { @MainActor in
                let newState: DownloadStatus = switch action {
                case .pause: .paused
                case .resume: .running
                case .cancel: .cancelled
                }
                DownloadStore.shared.update(id, status: newState)
            }
        }
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

    // 临时文件只在此回调期间有效；必须立即移动，而不是异步保存。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let marker = TaskMarker.decode(downloadTask.taskDescription) else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            let code = response.statusCode
            Task { @MainActor in
                let hint = code == 401 ? "登录凭据可能过期，请点重试" :
                           code == 403 ? "没有权限或下载受限" :
                           code == 404 ? "文件不存在或无权访问" : "请检查链接和网络"
                DownloadStore.shared.update(marker.id, status: .failed,
                    message: "HTTP \(code)：\(hint)")
            }
            return
        }
        do {
            let directory = DownloadStore.downloadFolder
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path)
            var candidate = marker.filename
            // 直链如果 URL 文件名泛泛，优先用服务器告知的文件名。
            if marker.source == .direct,
               (candidate == "download" || candidate == "file" || candidate.hasPrefix("下载文件_")),
               let suggested = downloadTask.response?.suggestedFilename {
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
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path)
            Task { @MainActor in
                DownloadStore.shared.update(marker.id, status: .completed,
                                            savedFilename: destination.lastPathComponent)
            }
        } catch {
            Task { @MainActor in
                DownloadStore.shared.update(marker.id, status: .failed,
                    message: "保存失败：\(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error, let marker = TaskMarker.decode(task.taskDescription) else { return }
        Task { @MainActor in
            let existing = DownloadStore.shared.items.first { $0.id == marker.id }
            guard let existing, existing.status != .cancelled,
                  existing.status != .paused, existing.status != .completed,
                  existing.status != .failed else { return }
            DownloadStore.shared.update(marker.id, status: .failed,
                                        message: error.localizedDescription)
        }
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
