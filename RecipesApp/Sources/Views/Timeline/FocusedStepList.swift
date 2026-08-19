import RecipeCore
import SwiftUI

struct FocusedStepList: View {
    let recipe: RecipeV1
    let servings: Decimal
    let units: UnitSystemPreference

    init(
        recipe: RecipeV1,
        servings: Decimal? = nil,
        units: UnitSystemPreference = .source
    ) {
        self.recipe = recipe
        self.servings = servings ?? recipe.recipeYield.servings
        self.units = units
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(recipe.sortedStages) { stage in
                stageCard(stage)
            }
        }
    }

    private func stageCard(_ stage: Stage) -> some View {
        let warnings = warnings(for: stage)
        let ingredients = enteringIngredients(for: stage)

        return VStack(alignment: .leading, spacing: 14) {
            stageHeader(stage, warnings: warnings)

            Text(stage.instruction)
                .font(.body)
                .foregroundStyle(RecipeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !ingredients.isEmpty {
                enteringIngredientsSection(ingredients)
            }

            if let completionCue = stage.completionCue, !completionCue.isEmpty {
                Label {
                    Text(completionCue)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(RecipeTheme.focusText)
                }
                .font(.subheadline.weight(.medium))
                .accessibilityLabel("Completion cue: \(completionCue)")
            }

            stageMetadata(stage)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecipeTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(RecipeTheme.grid)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: stage, ingredients: ingredients, warnings: warnings))
    }

    @ViewBuilder
    private func stageHeader(_ stage: Stage, warnings: [RecipeUncertainty]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                stageTitle(stage)
                Spacer(minLength: 12)
                if !warnings.isEmpty {
                    warningLabel(count: warnings.count)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 8) {
                stageTitle(stage)
                if !warnings.isEmpty {
                    warningLabel(count: warnings.count)
                }
            }
        }
    }

    private func stageTitle(_ stage: Stage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(stage.sortIndex + 1)")
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(RecipeTheme.focusText)
            Text(stage.action)
                .font(.title3.weight(.semibold))
                .foregroundStyle(RecipeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func warningLabel(count: Int) -> some View {
        Label(count == 1 ? "Source warning" : "\(count) source warnings", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(RecipeTheme.warning)
    }

    private func enteringIngredientsSection(_ ingredients: [EnteringIngredient]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Add now", systemImage: "arrow.right.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RecipeTheme.focusText)

            ForEach(ingredients) { ingredient in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ingredientQuantity(ingredient)
                        Text(ingredient.name)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    VStack(alignment: .leading, spacing: 2) {
                        ingredientQuantity(ingredient)
                        Text(ingredient.name)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(RecipeTheme.ink)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecipeTheme.focus.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(RecipeTheme.focus)
                .frame(width: 3)
                .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private func ingredientQuantity(_ ingredient: EnteringIngredient) -> some View {
        if let quantity = ingredient.quantity {
            Text(quantity)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func stageMetadata(_ stage: Stage) -> some View {
        let hasMetadata = stage.duration != nil || stage.temperature != nil || stage.heat != nil
        if hasMetadata {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    metadataItems(stage)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 8) {
                    metadataItems(stage)
                }
            }
            .font(.subheadline)
            .foregroundStyle(RecipeTheme.secondaryInk)
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    @ViewBuilder
    private func metadataItems(_ stage: Stage) -> some View {
        if let duration = stage.duration {
            Label(durationLabel(duration), systemImage: "timer")
                .monospacedDigit()
        }
        if let temperature = stage.temperature {
            Label(temperature.converted(for: units).displayString(), systemImage: "thermometer.medium")
        }
        if let heat = stage.heat {
            Label(heat.capitalized, systemImage: "flame")
        }
    }

    private func enteringIngredients(for stage: Stage) -> [EnteringIngredient] {
        let ingredientsByID = Dictionary(uniqueKeysWithValues: recipe.ingredients.map { ($0.id, $0) })
        let factor = recipe.recipeYield.servings > 0 ? servings / recipe.recipeYield.servings : 1

        return stage.ingredientUses.enumerated().compactMap { index, use in
            guard let ingredient = ingredientsByID[use.ingredientID] else { return nil }
            let quantity = (use.quantity ?? ingredient.quantity)?
                .scaled(by: factor, enabled: ingredient.scalable)
                .converted(for: units)
                .displayString()
            return EnteringIngredient(
                id: "\(stage.id)-\(use.ingredientID)-\(index)",
                name: ingredient.name,
                quantity: quantity,
                sortIndex: ingredient.sortIndex
            )
        }
        .sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }
    }

    private func warnings(for stage: Stage) -> [RecipeUncertainty] {
        recipe.uncertainties.filter { !$0.isResolved && $0.stageIDs.contains(stage.id) }
    }

    private func durationLabel(_ duration: StageDuration) -> String {
        let minimum = max(0, duration.minimumSeconds)
        guard let maximum = duration.maximumSeconds, maximum != minimum else {
            return durationValue(minimum)
        }

        if minimum < 60, maximum < 60 {
            return "\(minimum)–\(maximum) sec"
        }

        return "\(minuteValue(minimum))–\(minuteValue(maximum)) min"
    }

    private func durationValue(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) sec"
        }
        return "\(minuteValue(seconds)) min"
    }

    private func minuteValue(_ seconds: Int) -> String {
        (Double(seconds) / 60).formatted(.number.precision(.fractionLength(0...1)))
    }

    private func accessibilityLabel(
        for stage: Stage,
        ingredients: [EnteringIngredient],
        warnings: [RecipeUncertainty]
    ) -> String {
        var parts = ["Stage \(stage.sortIndex + 1), \(stage.action)", stage.instruction]

        if !ingredients.isEmpty {
            let ingredientText = ingredients.map { ingredient in
                [ingredient.quantity, ingredient.name].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: ", ")
            parts.append("Add now: \(ingredientText)")
        }
        if let completionCue = stage.completionCue, !completionCue.isEmpty {
            parts.append("Completion cue: \(completionCue)")
        }
        if let duration = stage.duration {
            parts.append("Duration: \(durationLabel(duration))")
        }
        if let temperature = stage.temperature {
            parts.append("Temperature: \(temperature.converted(for: units).displayString())")
        }
        if let heat = stage.heat {
            parts.append("Heat: \(heat)")
        }
        for warning in warnings {
            parts.append("Source warning: \(warning.message)")
        }

        return parts.joined(separator: ". ")
    }
}

private struct EnteringIngredient: Identifiable {
    let id: String
    let name: String
    let quantity: String?
    let sortIndex: Int
}
