import RecipeCore
import SwiftUI

struct IngredientSubstitutesRequest: Hashable, Identifiable, Sendable {
    let ingredient: Ingredient
    let servings: Decimal
    let originalServings: Decimal
    let units: UnitSystemPreference

    var id: String { ingredient.id }

    init(ingredient: Ingredient, recipe: RecipeV1, servings: Decimal, units: UnitSystemPreference) {
        self.ingredient = ingredient
        self.servings = servings
        self.originalServings = recipe.recipeYield.resolvedServings
        self.units = units
    }

    var substitutes: [IngredientSubstitute] {
        IngredientSubstitutions.substitutes(for: ingredient, servings: servings, originalServings: originalServings, units: units)
    }

    var displayQuantity: String? {
        ingredient.displayQuantity(servings: servings, originalServings: originalServings, units: units)
    }
}

/// Shows what can stand in for an ingredient, scaled to the servings and units on the recipe.
struct IngredientSubstitutesView: View {
    let request: IngredientSubstitutesRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let notes = request.ingredient.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        Label {
                            Text("Recipe note: \(notes)")
                        } icon: {
                            Image(systemName: "text.quote")
                        }
                        .font(.subheadline)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                    }
                    ForEach(request.substitutes) { substitute in
                        SubstituteCard(substitute: substitute)
                    }
                    Text("Substitutes can change the texture and flavour of the finished dish. Amounts follow the servings and units on the recipe.")
                        .font(.footnote)
                        .foregroundStyle(RecipeTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Substitutes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .editorialSurface()
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("ingredient-substitutes")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            EyebrowLabel("Instead of", color: RecipeTheme.focusText)
            Text(request.ingredient.name)
                .font(RecipeTheme.display(.title2))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let quantity = request.displayQuantity {
                Text("\(quantity) for \(request.servings.formatted()) serving\(request.servings == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(RecipeTheme.secondaryInk)
            }
        }
    }
}

private struct SubstituteCard: View {
    let substitute: IngredientSubstitute

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(substitute.title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(substitute.components.enumerated()), id: \.offset) { _, component in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(RecipeTheme.focus)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            .accessibilityHidden(true)
                        if let quantity = component.quantity {
                            Text(quantity.displayString())
                                .font(.body.weight(.semibold).monospacedDigit())
                        }
                        Text(component.name)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(substitute.note)
                .font(.subheadline)
                .foregroundStyle(RecipeTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("substitute-\(substitute.id)")
    }
}
