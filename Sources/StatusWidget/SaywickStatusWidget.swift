import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SaywickStatusWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SaywickActivityAttributes.self) { context in
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("Saywick · \(context.state.phase)").font(.headline)
                    Text(context.attributes.engine).font(.caption)
                }
                Spacer()
                Text(context.attributes.startedAt, style: .timer).monospacedDigit()
                Button(intent: StopSaywickRecording()) { Image(systemName: "stop.circle.fill") }
                    .accessibilityLabel("Stop Saywick recording")
            }
            .padding()
            .widgetURL(URL(string: "saywick://recorder?source=liveActivity"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Saywick", systemImage: "mic.fill") }
                DynamicIslandExpandedRegion(.trailing) { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("\(context.state.phase) · \(context.attributes.engine)")
                        Spacer()
                        Button(intent: StopSaywickRecording()) { Label("Stop", systemImage: "stop.circle.fill") }
                    }
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer).monospacedDigit().frame(width: 44)
            } minimal: { Image(systemName: "mic.fill").foregroundStyle(.red) }
            .widgetURL(URL(string: "saywick://recorder?source=liveActivity"))
        }
    }
}
