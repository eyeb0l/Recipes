import RecipeCore
import SwiftUI

struct FocusedStepList: View {
    let recipe: RecipeV1

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(recipe.sortedStages) { stage in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(stage.sortIndex + 1)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(RecipeTheme.focus)
                        Text(stage.action)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        if recipe.uncertainties.contains(where: { !$0.isResolved && $0.stageIDs.contains(stage.id) }) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(RecipeTheme.warning)
                        }
                    }
                    Text(stage.instruction)
                        .font(.body)
                    HStack(spacing: 14) {
                        if let duration = stage.duration {
                            Label("\(max(1, duration.minimumSeconds / 60)) min", systemImage: "timer")
                        }
                        if let temperature = stage.temperature {
                            Label(temperature.displayString(), systemImage: "thermometer.medium")
                        }
                        if let heat = stage.heat {
                            Label(heat.capitalized, systemImage: "flame")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(RecipeTheme.secondaryInk)
                }
                .padding(18)
                .background(RecipeTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(RecipeTheme.grid) }
            }
        }
    }
}
