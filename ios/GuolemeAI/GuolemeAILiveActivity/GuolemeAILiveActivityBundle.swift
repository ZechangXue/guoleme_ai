import ActivityKit
import SwiftUI
import WidgetKit

@main
struct GuolemeAILiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ListeningLiveActivity()
    }
}

struct ListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningAttributes.self) { context in
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.appName)
                        .font(.caption.weight(.semibold))
                    Text(context.state.modeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(context.state.statusLine)
                        .font(.footnote)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(12)
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.appName)
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.listeningLabel)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.statusLine)
                        .font(.footnote)
                        .lineLimit(3)
                }
            } compactLeading: {
                Image(systemName: "waveform")
            } compactTrailing: {
                Text(context.state.modeLabel)
                    .font(.caption2)
            } minimal: {
                Image(systemName: "waveform")
            }
        }
    }
}
