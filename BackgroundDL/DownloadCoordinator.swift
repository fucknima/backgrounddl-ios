import Foundation

@MainActor
final class DownloadCoordinator {
    static let shared = DownloadCoordinator()
    private init() {}

    func enqueue(request: URLRequest, originalURL: String, name: String, source: DownloadSource) {
        Task {
            let setting = UserDefaults.standard.string(forKey: "bgdl.downloadMode") ?? "smart"
            let mode = DownloadMode(rawValue: setting) ?? .smart
            // Captured browser requests may contain expiring cookies or signed URLs.
            // Keep them on the reliable single-task OS downloader.
            if source == .direct, mode != .stable,
               let result = await RangeProbe.check(request: request) {
                // A segmented merge can temporarily need one additional part's
                // worth of disk. Prefer stable mode rather than exhausting space.
                let estimated = result.size + result.size / Int64(mode.desiredParts) + 256 * 1024 * 1024
                let free = try? DownloadStore.downloadFolder.deletingLastPathComponent()
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
                if let free, free < estimated {
                    BackgroundDownloader.shared.enqueue(request: request, originalURL: originalURL,
                                                        name: name, source: source)
                    return
                }
                do {
                    try SegmentedDownloader.shared.start(request: request, originalURL: originalURL,
                                                         name: name, probe: result,
                                                         segments: mode.desiredParts)
                    return
                } catch {
                    NSLog("分段模式不可用，回退系统下载：%@", error.localizedDescription)
                }
            }
            BackgroundDownloader.shared.enqueue(request: request, originalURL: originalURL,
                                                name: name, source: source)
        }
    }

    func changeState(id: UUID, action: DownloadAction) {
        if SegmentedDownloader.shared.contains(id: id) {
            SegmentedDownloader.shared.changeState(id: id, action: action)
        } else {
            BackgroundDownloader.shared.changeState(id: id, action: action)
        }
    }

    func remove(id: UUID, deleteFile: Bool) throws {
        if SegmentedDownloader.shared.contains(id: id) {
            try DownloadStore.shared.remove(id: id, deleteFile: deleteFile)
            SegmentedDownloader.shared.remove(id: id)
        } else {
            try BackgroundDownloader.shared.remove(id: id, deleteFile: deleteFile)
        }
    }

    func reconnect() {
        SegmentedDownloader.shared.reconnect()
        BackgroundDownloader.shared.reconnect()
    }
}
