import Foundation

// Only transient connection failures are auto-retried. HTTP 401/403, corrupt
// Range responses, short files, and exhausted disk are never retried blindly.
@MainActor
final class DownloadRetryManager {
    static let shared = DownloadRetryManager()
    private var scheduled = Set<UUID>()
    private init() {}

    func schedule(id: UUID, error: NSError, resumeData: Data?) -> Bool {
        let transient: Set<Int> = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                                   NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
                                   NSURLErrorCannotFindHost]
        guard error.domain == NSURLErrorDomain, transient.contains(error.code),
              let item = DownloadStore.shared.items.first(where: { $0.id == id }),
              item.source == .direct, (item.retries ?? 0) < 3 else { return false }
        let attempts = (item.retries ?? 0) + 1
        let delay = TimeInterval([3, 12, 45][attempts - 1])
        if let resumeData { DownloadStore.shared.setResumeData(id, data: resumeData) }
        DownloadStore.shared.scheduleRetry(id: id, count: attempts, after: delay)
        schedulePending(id: id)
        return true
    }

    func resumePending() {
        for item in DownloadStore.shared.items where item.nextRetryAt != nil {
            schedulePending(id: item.id)
        }
    }

    private func schedulePending(id: UUID) {
        guard !scheduled.contains(id),
              let item = DownloadStore.shared.items.first(where: { $0.id == id }),
              let next = item.nextRetryAt else { return }
        scheduled.insert(id)
        Task { @MainActor in
            let wait = max(0, next.timeIntervalSinceNow)
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            scheduled.remove(id)
            guard let latest = DownloadStore.shared.items.first(where: { $0.id == id }),
                  latest.nextRetryAt == next, latest.status != .cancelled else { return }
            BackgroundDownloader.shared.retryExisting(id: id)
        }
    }
}
