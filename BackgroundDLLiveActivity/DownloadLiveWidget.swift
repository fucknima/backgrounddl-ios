import ActivityKit
import SwiftUI
import WidgetKit

private func clamped(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
}

struct DownloadLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.cyan)
                    Text(context.attributes.filename)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 5)
                    Text(context.state.expected > 0
                         ? "\(Int(clamped(context.state.fraction) * 100))%" : "下载中")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                ProgressView(value: clamped(context.state.fraction))
                    .tint(.cyan)
                Text("已下载 \(ByteCountFormatter.string(fromByteCount: context.state.written, countStyle: .file))" +
                     (context.state.expected > 0
                      ? " / \(ByteCountFormatter.string(fromByteCount: context.state.expected, countStyle: .file))" : ""))
                    .font(.caption)
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
                    Text(context.state.expected > 0
                         ? "\(Int(clamped(context.state.fraction) * 100))%" : "···")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(context.attributes.filename)
                            .font(.caption)
                            .lineLimit(1)
                        ProgressView(value: clamped(context.state.fraction))
                            .tint(.cyan)
                        Text("\(ByteCountFormatter.string(fromByteCount: context.state.written, countStyle: .file)) 已下载")
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
