import XCTest
@testable import RecipeCore

final class IngredientSubstitutionTests: XCTestCase {
    func testTheMostSpecificRuleWinsAndLookalikeIngredientsAreSkipped() {
        XCTAssertEqual(IngredientSubstitutions.rule(for: "unsalted butter")?.id, "unsalted-butter")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "Butter, softened")?.id, "butter")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "buttermilk")?.id, "buttermilk")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "large eggs")?.id, "egg")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "Self-raising flour")?.id, "self-raising-flour")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "Crème fraîche")?.id, "creme-fraiche")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "garlic cloves, crushed")?.id, "garlic")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "fresh espresso")?.id, "espresso")

        for name in ["peanut butter", "butternut squash", "egg yolks", "garlic powder", "coconut milk", "milk chocolate", "dried thyme", ""] {
            XCTAssertFalse(IngredientSubstitutions.hasSubstitutes(for: name), name)
        }
    }

    func testAmountsFollowTheServingsAndUnitsBeingCooked() throws {
        let recipe = SampleRecipe.espressoBrownies
        let butter = try XCTUnwrap(recipe.ingredients.first { $0.id == "butter" })

        let doubled = IngredientSubstitutions.substitutes(for: butter, servings: 18, originalServings: 9, units: .metric)
        let oil = try XCTUnwrap(doubled.first { $0.id == "unsalted-butter.oil" })
        XCTAssertEqual(oil.components.map(\.name), ["neutral oil"])
        XCTAssertEqual(oil.components.first?.quantity?.displayString(), "184 g")

        let imperial = IngredientSubstitutions.substitutes(for: butter, servings: 9, originalServings: 9, units: .imperial)
        let salted = try XCTUnwrap(imperial.first { $0.id == "unsalted-butter.salted" })
        XCTAssertEqual(salted.components.first?.quantity?.unit, .ounce)
    }

    func testSubstitutesThatChangeUnitsScaleFromTheOriginalAmount() throws {
        let recipe = SampleRecipe.espressoBrownies
        let eggs = try XCTUnwrap(recipe.ingredients.first { $0.id == "eggs" })
        let flax = try XCTUnwrap(
            IngredientSubstitutions.substitutes(for: eggs, servings: 18, originalServings: 9, units: .source).first { $0.id == "egg.flax" }
        )
        XCTAssertEqual(flax.components.map { $0.quantity?.displayString() }, ["4 tbsp", "12 tbsp"])

        let espresso = try XCTUnwrap(recipe.ingredients.first { $0.id == "espresso" })
        let powder = try XCTUnwrap(
            IngredientSubstitutions.substitutes(for: espresso, servings: 9, originalServings: 9, units: .source).first
        )
        XCTAssertEqual(powder.components.map { $0.quantity?.displayString() }, ["1 tsp", "60 ml"])
    }

    func testRangesScaleAndAmountsThatCantBeWorkedOutAreLeftBlank() throws {
        let garlic = Ingredient(name: "garlic cloves", quantity: .range(2, 3, unit: .clove), sortIndex: 0)
        let granules = try XCTUnwrap(
            IngredientSubstitutions.substitutes(for: garlic, servings: 1, originalServings: 1, units: .source).first
        )
        let range = try XCTUnwrap(granules.components.first?.quantity)
        XCTAssertEqual(range.kind, .range)
        XCTAssertEqual(range.lower, 0.25)
        XCTAssertEqual(range.upper, 0.375)

        let sprigs = Ingredient(name: "thyme", quantity: .exact(4, unit: .sprig), sortIndex: 0)
        let dried = IngredientSubstitutions.substitutes(for: sprigs, servings: 1, originalServings: 1, units: .source)
        XCTAssertEqual(dried.count, 1)
        XCTAssertNil(dried.first?.components.first?.quantity)

        let chopped = Ingredient(name: "fresh parsley, chopped", quantity: .exact(3, unit: .tablespoon), sortIndex: 0)
        XCTAssertEqual(
            IngredientSubstitutions.substitutes(for: chopped, servings: 1, originalServings: 1, units: .source)
                .first?.components.first?.quantity?.displayString(),
            "1 tbsp"
        )

        let toTaste = Ingredient(name: "lemon juice", quantity: .qualitative("a squeeze"), sortIndex: 0)
        let lime = try XCTUnwrap(IngredientSubstitutions.substitutes(for: toTaste, servings: 1, originalServings: 1, units: .metric).first)
        XCTAssertEqual(lime.components.map(\.name), ["lime juice"])
        XCTAssertNil(lime.components.first?.quantity)
    }

    func testUnscalableIngredientsKeepTheirAmountWhenServingsChange() throws {
        let stock = Ingredient(name: "chicken stock", quantity: .exact(500, unit: .milliliter), scalable: false, sortIndex: 0)
        let cube = try XCTUnwrap(IngredientSubstitutions.substitutes(for: stock, servings: 8, originalServings: 4, units: .source).first)
        XCTAssertEqual(cube.components.map { $0.quantity?.displayString() }, ["1", "500 ml"])
    }
}

final class ShoppingListTests: XCTestCase {
    func testItemsAreScaledNamedForAListAndInRecipeOrder() throws {
        let items = ShoppingList.items(for: SampleRecipe.espressoBrownies, servings: 18, units: .metric)
        XCTAssertEqual(items.count, 9)
        XCTAssertEqual(items.first?.name, "Unsalted butter")
        XCTAssertEqual(items.first?.quantity, "230 g")
        XCTAssertEqual(items.first { $0.id == "eggs" }?.quantity, "4")
    }

    func testRepeatedIngredientsAreCombinedAndAddedUpWhenTheUnitsAllow() {
        let recipe = RecipeV1(
            title: "Layer cake",
            recipeYield: .init(servings: 4),
            ingredients: [
                .init(id: "sugar-cake", name: "caster sugar", quantity: .exact(200, unit: .gram), sortIndex: 0),
                .init(id: "flour", name: "plain flour", quantity: .exact(250, unit: .gram), sortIndex: 1),
                .init(id: "sugar-icing", name: "Caster sugar", quantity: .exact(0.1, unit: .kilogram), sortIndex: 2),
                .init(id: "flour-dusting", name: "plain flour", quantity: .qualitative("for dusting"), sortIndex: 3),
                .init(id: "egg", name: "large egg", quantity: .exact(1, unit: .count), sortIndex: 4),
                .init(id: "eggs", name: "Large eggs", quantity: .exact(2, unit: .count), sortIndex: 5)
            ],
            stages: [],
            provenance: .init(sourceType: .manual)
        )

        let items = ShoppingList.items(for: recipe, servings: 4, units: .metric)

        XCTAssertEqual(items.map(\.name), ["Caster sugar", "Plain flour", "Large egg"])
        XCTAssertEqual(items[0].ingredientIDs, ["sugar-cake", "sugar-icing"])
        XCTAssertEqual(items[0].quantity, "300 g")
        XCTAssertEqual(items[1].quantity, "250 g + for dusting")
        XCTAssertEqual(items[2].quantity, "3")
    }

    func testPlanReusesMatchingRemindersAndNeverDuplicatesARecipe() {
        let items = [
            ShoppingListItem(id: "eggs", ingredientIDs: ["eggs"], name: "Large eggs", quantity: "2"),
            ShoppingListItem(id: "flour", ingredientIDs: ["flour"], name: "Plain flour", quantity: "80 g"),
            ShoppingListItem(id: "salt", ingredientIDs: ["salt"], name: "Table salt", quantity: nil)
        ]
        let existing = [
            ExistingShoppingReminder(id: "r1", title: "large egg", notes: "6 · Pancakes"),
            ExistingShoppingReminder(id: "r2", title: "Table salt", notes: "Brownies")
        ]

        let plan = ShoppingList.plan(adding: items, recipeTitle: "Brownies", to: existing)

        XCTAssertEqual(plan.newReminders, [.init(title: "Plain flour", notes: "80 g · Brownies")])
        XCTAssertEqual(plan.notesUpdates, [.init(reminderID: "r1", notes: "6 · Pancakes\n2 · Brownies")])
        XCTAssertEqual(plan.alreadyListedCount, 1)

        let afterAdding = [
            ExistingShoppingReminder(id: "r1", title: "large egg", notes: "6 · Pancakes\n2 · Brownies"),
            ExistingShoppingReminder(id: "r2", title: "Table salt", notes: "Brownies"),
            ExistingShoppingReminder(id: "r3", title: "Plain flour", notes: "80 g · Brownies")
        ]
        let again = ShoppingList.plan(adding: items, recipeTitle: "Brownies", to: afterAdding)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.alreadyListedCount, 3)

        let rescaled = [ShoppingListItem(id: "eggs", ingredientIDs: ["eggs"], name: "Large eggs", quantity: "4")]
        let replaced = ShoppingList.plan(adding: rescaled, recipeTitle: "Brownies", to: afterAdding)
        XCTAssertEqual(replaced.notesUpdates, [.init(reminderID: "r1", notes: "6 · Pancakes\n4 · Brownies")])
    }
}
