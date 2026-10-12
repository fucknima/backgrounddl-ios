import ActivityKit
import Foundation

@MainActor
final class DownloadActivityManager {
    static let shared = DownloadActivityManager()
    private var lastUpdateAt = Date.distantPast
    private var lastRenderedID: UUID?
    private var lastRenderedPhase = ""

    private init() {}

    func refresh(_ items: [DownloadItem], force: Bool = false) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let activeItem = items.first(where: { $0.status == .running })
        let existing = Activity<DownloadActivityAttributes>.activities
        guard let active = activeItem else {
            for activity in existing {
                let item = items.first { $0.id.uuidString == activity.attributes.downloadID }
                let old = activity.content.state
                let state = DownloadActivityAttributes.ContentState(
                    fraction: item?.fraction ?? old.fraction,
                    written: item?.downloadedBytes ?? old.written,
                    expected: item?.totalBytes ?? old.expected,
                    phase: item?.status.rawValue ?? "completed",
                    speedBytesPerSecond: nil,
                    etaSeconds: nil,
                    lastUpdated: Date()
                )
                Task {
                    await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8)))
                }
            }
            lastRenderedID = nil
            lastRenderedPhase = ""
            return
        }

        let currentActivities = existing.filter { $0.attributes.downloadID == active.id.uuidString }
        for obsolete in existing where obsolete.attributes.downloadID != active.id.uuidString {
            Task { await obsolete.end(nil, dismissalPolicy: .immediate) }
        }

        let phase = active.status.rawValue
        let now = Date()
        if !force, lastRenderedID == active.id, lastRenderedPhase == phase,
           now.timeIntervalSince(lastUpdateAt) < 2.0 { return }
        lastRenderedID = active.id
        lastRenderedPhase = phase
        lastUpdateAt = now

        let state = DownloadActivityAttributes.ContentState(
            fraction: active.fraction ?? -1,
            written: active.downloadedBytes,
            expected: active.totalBytes,
            phase: phase,
            speedBytesPerSecond: active.speedBytesPerSecond,
            etaSeconds: active.etaSeconds,
            lastUpdated: now
        )
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(60))
        if let activity = currentActivities.first {
            Task { await activity.update(content) }
        } else {
            let attributes = DownloadActivityAttributes(downloadID: active.id.uuidString,
                                                       filename: String(active.filename.prefix(96)))
            do {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                NSLog("无法创建灵动岛下载活动: %@", error.localizedDescription)
            }
        }
    }
}
