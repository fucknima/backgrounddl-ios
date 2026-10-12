import ActivityKit
import SwiftUI
import WidgetKit

private func clamped(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
}

private func speedLabel(_ speed: Double?) -> String {
    guard let speed, speed > 0 else { return "速度 --" }
    return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
}

private func etaLabel(_ eta: Double?) -> String {
    guard let eta, eta.isFinite, eta > 0 else { return "预计 --" }
    let s = Int(eta.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    if h > 0 { return String(format: "预计 %dh %02dm", h, m) }
    if m > 0 { return String(format: "预计 %dm", m) }
    return "预计 \(s)s"
}

struct DownloadLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.filename)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.phase == "running" ? "后台下载中" : "任务状态已更新")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(context.state.expected > 0 ? "\(Int(clamped(context.state.fraction) * 100))%" : "下载中")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                ProgressView(value: clamped(context.state.fraction))
                    .tint(.cyan)
                HStack {
                    Text("已下载 \(ByteCountFormatter.string(fromByteCount: context.state.written, countStyle: .file))")
                    Spacer()
                    if context.state.expected > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: context.state.expected, countStyle: .file))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Label(speedLabel(context.state.speedBytesPerSecond), systemImage: "speedometer")
                    Spacer()
                    Label(etaLabel(context.state.etaSeconds), systemImage: "clock")
                }
                .font(.caption)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("上次进度更新")
                    Text(context.state.lastUpdated, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .activityBackgroundTint(Color(white: 0.11))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("后台下载", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.expected > 0 ? "\(Int(clamped(context.state.fraction) * 100))%" : "···")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.attributes.filename)
                            .font(.caption)
                            .lineLimit(1)
                        ProgressView(value: clamped(context.state.fraction))
                            .tint(.cyan)
                        HStack {
                            Text(speedLabel(context.state.speedBytesPerSecond))
                            Spacer()
                            Text(etaLabel(context.state.etaSeconds))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                if context.state.expected > 0 {
                    Text("\(Int(clamped(context.state.fraction) * 100))%")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                } else {
                    Image(systemName: "ellipsis")
                }
            } minimal: {
                if context.state.expected > 0 {
                    ProgressView(value: clamped(context.state.fraction))
                        .progressViewStyle(.circular)
                        .tint(.cyan)
                } else {
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.cyan)
                }
            }
            .keylineTint(.cyan)
        }
    }
}

@main
struct DownloadLiveWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveWidget()
    }
}
