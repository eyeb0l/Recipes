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

        XCTAssertEqual(IngredientSubstitutions.rule(for: "confectioner's sugar")?.id, "icing-sugar")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "confectioner’s sugar")?.id, "icing-sugar")
        XCTAssertEqual(IngredientSubstitutions.rule(for: "confectioners' sugar")?.id, "icing-sugar")

        for name in [
            "peanut butter", "sunflower seed butter", "butternut squash", "egg yolks", "garlic powder",
            "coconut milk", "milk chocolate", "dried thyme", ""
        ] {
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

        // A whole vanilla pod replaces a tablespoon of extract; a teaspoon for one of 24 servings is too
        // little of a pod to show, so it's left blank rather than shown as "0".
        let vanilla = Ingredient(name: "vanilla extract", quantity: .exact(1, unit: .teaspoon), sortIndex: 0)
        let pod = { (servings: Decimal) in
            IngredientSubstitutions.substitutes(for: vanilla, servings: servings, originalServings: 24, units: .source)
                .first { $0.id == "vanilla.pod" }?.components.first
        }
        XCTAssertEqual(pod(24)?.quantity?.displayString(), "⅓")
        XCTAssertEqual(pod(3)?.quantity?.displayString(), "0.04")
        XCTAssertNotNil(pod(1))
        XCTAssertNil(pod(1)?.quantity)

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
        XCTAssertEqual(plan.notesUpdates, [.init(reminderID: "r1", notes: "6 · Pancakes\n2 · Brownies", previousNotes: "6 · Pancakes", previousTitle: "large egg")])
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
        XCTAssertEqual(
            replaced.notesUpdates,
            [.init(reminderID: "r1", notes: "6 · Pancakes\n4 · Brownies", previousNotes: "6 · Pancakes\n2 · Brownies", previousTitle: "large egg")]
        )
    }

    func testPlanKeepsNotesItDidNotWriteExactlyAsTheyWere() {
        let eggs = [ShoppingListItem(id: "eggs", ingredientIDs: ["eggs"], name: "Eggs", quantity: "2")]
        let personal = "  Organic only · Brownies\r\n\nfree range"
        let plan = ShoppingList.plan(
            adding: eggs,
            recipeTitle: "Brownies",
            to: [ExistingShoppingReminder(id: "r1", title: "eggs", notes: personal)]
        )
        XCTAssertEqual(plan.notesUpdates.first?.notes, personal + "\n2 · Brownies")

        // "Walnut · Brownies" is a different recipe whose title ends the same way.
        let otherRecipe = ShoppingList.plan(
            adding: eggs,
            recipeTitle: "Brownies",
            to: [ExistingShoppingReminder(id: "r1", title: "eggs", notes: "4 · Walnut · Brownies\n")]
        )
        XCTAssertEqual(otherRecipe.notesUpdates.first?.notes, "4 · Walnut · Brownies\n2 · Brownies")

        let fractional = ShoppingList.plan(
            adding: eggs,
            recipeTitle: "Brownies",
            to: [ExistingShoppingReminder(id: "r1", title: "eggs", notes: "Shopping\n  ½ · Brownies")]
        )
        XCTAssertEqual(fractional.notesUpdates.first?.notes, "Shopping\n2 · Brownies")

        // Line breaks other than "\n" still separate lines, and are kept.
        let otherBreaks = ShoppingList.plan(
            adding: eggs,
            recipeTitle: "Brownies",
            to: [ExistingShoppingReminder(id: "r1", title: "eggs", notes: "2 bags already at home\r4 · Brownies\r\nfree range")]
        )
        XCTAssertEqual(otherBreaks.notesUpdates.first?.notes, "2 bags already at home\r2 · Brownies\r\nfree range")
    }

    func testAMixedAmountIsReplacedWhenTheRecipeIsAddedAtOtherServings() throws {
        let recipe = RecipeV1(
            title: "Brownies",
            recipeYield: .init(servings: 4),
            ingredients: [
                .init(id: "salt-pinch", name: "sea salt", quantity: .qualitative("a pinch · for finishing"), sortIndex: 0),
                .init(id: "salt", name: "sea salt", quantity: .exact(2, unit: .teaspoon), sortIndex: 1)
            ],
            stages: [],
            provenance: .init(sourceType: .manual)
        )
        let four = try XCTUnwrap(ShoppingList.items(for: recipe, servings: 4, units: .source).first)
        XCTAssertEqual(four.quantity, "a pinch · for finishing + 2 tsp")

        let eight = ShoppingList.items(for: recipe, servings: 8, units: .source)
        let existing = ExistingShoppingReminder(
            id: "r1", title: "Sea salt", notes: ShoppingList.reminderNote(for: four, recipeTitle: "Brownies")
        )
        let plan = ShoppingList.plan(adding: eight, recipeTitle: "Brownies", to: [existing])
        XCTAssertEqual(plan.notesUpdates.first?.notes, "a pinch · for finishing + 4 tsp · Brownies")
    }

    func testATitleWithSpacesAroundItIsRecognisedWhenAddedAgain() {
        let eggs = { (quantity: String) in [ShoppingListItem(id: "eggs", ingredientIDs: ["eggs"], name: "Eggs", quantity: quantity)] }
        let note = ShoppingList.reminderNote(for: eggs("2")[0], recipeTitle: "Stew ")
        XCTAssertEqual(note, "2 · Stew")
        let existing = [ExistingShoppingReminder(id: "r1", title: "eggs", notes: note)]

        XCTAssertTrue(ShoppingList.plan(adding: eggs("2"), recipeTitle: "Stew ", to: existing).isEmpty)
        XCTAssertEqual(
            ShoppingList.plan(adding: eggs("4"), recipeTitle: "Stew ", to: existing).notesUpdates.first?.notes,
            "4 · Stew"
        )
    }

    func testOnlyALineShapedLikeTheRecipesOwnIsReplaced() {
        let garlic = [ShoppingListItem(id: "garlic", ingredientIDs: ["garlic"], name: "Garlic cloves", quantity: "2 cloves")]
        let plan = { (notes: String) in
            ShoppingList.plan(
                adding: garlic,
                recipeTitle: "Stew",
                to: [ExistingShoppingReminder(id: "r1", title: "garlic clove", notes: notes)]
            ).notesUpdates.first?.notes
        }

        XCTAssertEqual(plan("1 clove · Stew"), "2 cloves · Stew")
        XCTAssertEqual(plan("1½ cloves · Stew"), "2 cloves · Stew")
        // A note of the person's own that happens to start with a number is kept.
        XCTAssertEqual(
            plan("2 dozen in the cupboard · Stew\n1 clove · Stew"),
            "2 dozen in the cupboard · Stew\n2 cloves · Stew"
        )
        // Another recipe whose title differs only in a number keeps its line.
        XCTAssertEqual(plan("1 clove · Stew 2"), "1 clove · Stew 2\n2 cloves · Stew")
        // Numbers grouped the way some locales group them still count as one number.
        XCTAssertEqual(plan("1\u{202F}200,5 cloves · Stew"), "2 cloves · Stew")
        XCTAssertEqual(plan("۱٬۲۰۰٫۴۲ cloves · Stew"), "2 cloves · Stew")
        // A placeholder isn't a number.
        XCTAssertEqual(plan("# cloves · Stew"), "# cloves · Stew\n2 cloves · Stew")
        // Scaling, or switching unit system, can change the unit but not what it measures.
        let flour = { (quantity: String, notes: String) in
            ShoppingList.plan(
                adding: [ShoppingListItem(id: "flour", ingredientIDs: ["flour"], name: "Flour", quantity: quantity)],
                recipeTitle: "Stew",
                to: [ExistingShoppingReminder(id: "r1", title: "flour", notes: notes)]
            ).notesUpdates.first?.notes
        }
        XCTAssertEqual(flour("1.2 kg", "600 g · Stew"), "1.2 kg · Stew")
        XCTAssertEqual(flour("1 lb", "600 g · Stew"), "1 lb · Stew")
        XCTAssertEqual(flour("4 fl oz", "120 ml · Stew"), "4 fl oz · Stew")
        XCTAssertEqual(flour("1.2 kg", "500 ml · Stew"), "500 ml · Stew\n1.2 kg · Stew", "Weight never replaces volume")
        // When it's unclear which line the app wrote, nothing is replaced.
        XCTAssertEqual(plan("1 clove · Stew\n3 cloves · Stew"), "1 clove · Stew\n3 cloves · Stew\n2 cloves · Stew")
    }
}
