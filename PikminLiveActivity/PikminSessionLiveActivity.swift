import ActivityKit
import SwiftUI
import WidgetKit

struct PikminSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PikminSessionAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color(red: 0.06, green: 0.13, blue: 0.08))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.phase, systemImage: phaseSymbol(context.state.phase))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(String(format: "%.1f km/h", context.state.speedKilometersPerHour))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    metrics(context.state)
                }
            } compactLeading: {
                Image(systemName: phaseSymbol(context.state.phase))
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.steps)")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "location.fill")
                    .foregroundStyle(.green)
            }
            .widgetURL(URL(string: "pikminhelper://session"))
            .keylineTint(.green)
        }
    }

    private func lockScreenView(
        _ context: ActivityViewContext<PikminSessionAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Pikmin Helper", systemImage: "location.fill.viewfinder")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                Text(context.state.phase)
                    .font(.subheadline.weight(.semibold))
            }
            metrics(context.state)
            Text(String(
                format: "%.5f, %.5f",
                context.state.latitude,
                context.state.longitude
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding()
        .widgetURL(URL(string: "pikminhelper://session"))
    }

    private func metrics(_ state: PikminSessionAttributes.ContentState) -> some View {
        HStack(spacing: 18) {
            metric(value: state.steps.formatted(), label: "步", symbol: "figure.walk")
            metric(
                value: String(format: "%.2f", state.distanceKilometers),
                label: "公里",
                symbol: "point.topleft.down.to.point.bottomright.curvepath"
            )
            metric(
                value: String(format: "%.1f", state.speedKilometersPerHour),
                label: "km/h",
                symbol: "speedometer"
            )
        }
    }

    private func metric(value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.subheadline.bold().monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func phaseSymbol(_ phase: String) -> String {
        if phase.contains("暂停") { return "pause.circle.fill" }
        if phase.contains("重连") || phase.contains("中断") {
            return "exclamationmark.triangle.fill"
        }
        if phase.contains("完成") { return "checkmark.circle.fill" }
        return "location.fill"
    }
}
