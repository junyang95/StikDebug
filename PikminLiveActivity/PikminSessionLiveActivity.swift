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
                    HStack(spacing: 5) {
                        LivePikminBounce(
                            phase: context.state.phase,
                            size: 27,
                            amplitude: 2.4
                        )
                        Text(context.state.phase)
                    }
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
                LivePikminBounce(
                    phase: context.state.phase,
                    size: 22,
                    amplitude: 1.8
                )
            } compactTrailing: {
                Text("\(context.state.steps)")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                LivePikminBounce(
                    phase: context.state.phase,
                    size: 21,
                    amplitude: 1.6
                )
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
                LivePikminBounce(
                    phase: context.state.phase,
                    size: 30,
                    amplitude: 0
                )
                Text("StikDebug")
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

}

private struct LivePikminBounce: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let phase: String
    let size: CGFloat
    let amplitude: CGFloat

    private var isAnimating: Bool {
        let inactiveMarkers = ["暂停", "完成", "中断", "paused", "completed", "failed"]
        return amplitude > 0 && !inactiveMarkers.contains { marker in
            phase.localizedCaseInsensitiveContains(marker)
        }
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 15,
            paused: reduceMotion || !isAnimating
        )) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let wave = abs(sin(elapsed * .pi * 2 / 0.72))
            let lift = reduceMotion || !isAnimating ? 0 : wave * amplitude

            Image("PikminSprout")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .offset(y: -lift)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
