import ActivityKit
import RecipeCore
import SwiftUI
import WidgetKit

struct RecipeCookActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookActivityAttributes.self) { context in
            LockScreenCookView(context: context)
                .activityBackgroundTint(Color(red: 0.12, green: 0.105, blue: 0.09))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "recipetimeline://cook?session=\(context.attributes.sessionID)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "fork.knife")
                        .foregroundStyle(.pink)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.recipeTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(context.state.focusedAction)
                            .font(.headline)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerLabel(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityActions(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.pink)
            } compactTrailing: {
                TimerLabel(state: context.state)
                    .font(.caption2)
            } minimal: {
                Image(systemName: context.state.isComplete ? "checkmark" : "timer")
                    .foregroundStyle(.pink)
            }
            .widgetURL(URL(string: "recipetimeline://cook?session=\(context.attributes.sessionID)"))
        }
    }
}

private struct LockScreenCookView: View {
    let context: ActivityViewContext<CookActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.recipeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(context.state.focusedAction)
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                TimerLabel(state: context.state)
            }
            ProgressView(value: Double(context.state.completedStageCount), total: Double(max(context.state.totalStageCount, 1)))
                .tint(.pink)
            ActivityActions(attributes: context.attributes, state: context.state)
        }
        .padding()
        .foregroundStyle(.white)
    }
}

private struct TimerLabel: View {
    let state: CookActivityAttributes.ContentState

    var body: some View {
        if let end = state.nearestTimerEnd {
            VStack(alignment: .trailing, spacing: 1) {
                Text(end, style: .timer)
                    .monospacedDigit()
                    .font(.headline)
                if state.runningTimerCount > 1 {
                    Text("+\(state.runningTimerCount - 1)")
                        .font(.caption2)
                }
            }
            .accessibilityLabel(state.nearestTimerLabel ?? "Cooking timer")
        } else {
            Text("\(state.completedStageCount)/\(state.totalStageCount)")
                .monospacedDigit()
        }
    }
}

private struct ActivityActions: View {
    let attributes: CookActivityAttributes
    let state: CookActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            if let stageID = state.focusedStageID, !state.isComplete {
                Button(intent: CompleteCookStageIntent(sessionID: attributes.sessionID, stageID: stageID)) {
                    Label("Complete", systemImage: "checkmark.circle.fill")
                }
                .tint(.pink)
            }
            if let timerID = state.nearestTimerID, let stageID = state.nearestTimerStageID {
                Button(intent: ToggleCookTimerIntent(sessionID: attributes.sessionID, stageID: stageID, timerID: timerID)) {
                    Label("Pause timer", systemImage: "pause.fill")
                }
                .tint(.gray)
            }
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.titleAndIcon)
    }
}
