import ActivityKit
import Foundation
import BackgroundTasks
import UIKit

@MainActor
final class DownloadActivityManager {
    static let shared = DownloadActivityManager()
    private var lastUpdateAt = Date.distantPast
    private var lastRenderedID: UUID?
    private var lastRenderedPhase = ""

    private init() {}

    func refresh(_ items: [DownloadItem], force: Bool = false) {
        if #available(iOS 26.0, *),
           ContinuedDownloadProgress.shared.isSystemProgressActive {
            // The iOS 26 task has its own OS-owned Live Activity. Avoid duplicate islands.
            for activity in Activity<DownloadActivityAttributes>.activities {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
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


// iOS 26+ system-owned task progress. The background URLSession is still the
// transport and the source of truth; this optional continued task merely keeps
// user-initiated download orchestration and progress reporting alive where the
// OS grants runtime. Expiration does not cancel the durable system transfer.
@available(iOS 26.0, *)
@MainActor
final class ContinuedDownloadProgress {
    static let shared = ContinuedDownloadProgress()
    private var identifier: String {
        (Bundle.main.bundleIdentifier ?? "com.example.backgrounddl") + ".downloadProgress"
    }
    private var pendingID: UUID?
    private var trackingID: UUID?
    private var systemTask: BGContinuedProcessingTask?
    private var observation: Task<Void, Never>?
    private var isRegistered = false
    var isSystemProgressActive: Bool { systemTask != nil }

    func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { incoming in
            guard let task = incoming as? BGContinuedProcessingTask else {
                incoming.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in self.begin(task) }
        }
        if !isRegistered {
            NSLog("iOS 26 系统进度任务注册未成功，使用旧版实时活动")
        }
    }

    func startIfPossible(_ item: DownloadItem) {
        guard isRegistered, UIApplication.shared.applicationState == .active,
              pendingID == nil, systemTask == nil,
              item.status == .running else { return }
        // Do not queue invisible work: fallback Live Activity must remain available.
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "后台下载",
            subtitle: String(item.filename.prefix(55))
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            pendingID = item.id
        } catch {
            NSLog("系统进度不可用，继续使用旧版灵动岛: %@", error.localizedDescription)
        }
    }

    private func begin(_ task: BGContinuedProcessingTask) {
        guard systemTask == nil, let id = pendingID,
              let item = DownloadStore.shared.items.first(where: { $0.id == id }),
              item.status == .running else {
            pendingID = nil
            task.setTaskCompleted(success: false)
            return
        }
        pendingID = nil
        trackingID = id
        systemTask = task
        task.progress.totalUnitCount = max(1, item.totalBytes)
        task.progress.completedUnitCount = max(0, min(item.downloadedBytes, task.progress.totalUnitCount))
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.finish(success: false) }
        }
        DownloadActivityManager.shared.refresh(DownloadStore.shared.items, force: true)
        observation?.cancel()
        observation = Task { @MainActor in
            while !Task.isCancelled, systemTask === task {
                guard let item = DownloadStore.shared.items.first(where: { $0.id == id }) else {
                    finish(success: false); break
                }
                if item.status != .running {
                    finish(success: item.status == .completed)
                    break
                }
                synchronize(item)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func synchronize(_ item: DownloadItem) {
        guard item.id == trackingID, let task = systemTask else { return }
        if item.status != .running {
            finish(success: item.status == .completed)
            return
        }
        // The system renders its own Live Activity from NSProgress.
        // Never estimate downloaded bytes or invent progress while callbacks stop.
        if item.totalBytes > 0 {
            task.progress.totalUnitCount = item.totalBytes
            task.progress.completedUnitCount = max(0, min(item.downloadedBytes, item.totalBytes))
        }
        let percent = item.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "大小未知"
        task.updateTitle("后台下载", subtitle: "\(String(item.filename.prefix(34))) · \(percent)")
    }

    private func finish(success: Bool) {
        observation?.cancel()
        observation = nil
        guard let task = systemTask else { return }
        task.expirationHandler = nil
        systemTask = nil
        trackingID = nil
        task.setTaskCompleted(success: success)
        // Restore legacy Live Activity if the system task expired but transfer lives.
        DownloadActivityManager.shared.refresh(DownloadStore.shared.items, force: true)
    }
}
