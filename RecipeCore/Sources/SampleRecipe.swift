import Foundation

public enum SampleRecipe {
    public static let espressoBrownies: RecipeV1 = {
        let butter = Ingredient(id: "butter", name: "unsalted butter", quantity: .exact(115, unit: .gram), sortIndex: 0)
        let sugar = Ingredient(id: "sugar", name: "caster sugar", quantity: .exact(200, unit: .gram), sortIndex: 1)
        let vanilla = Ingredient(id: "vanilla", name: "vanilla extract", quantity: .exact(2.5, unit: .milliliter), sortIndex: 2)
        let espresso = Ingredient(id: "espresso", name: "fresh espresso", quantity: .exact(60, unit: .milliliter), sortIndex: 3)
        let eggs = Ingredient(id: "eggs", name: "large eggs", quantity: .exact(2, unit: .count), sortIndex: 4)
        let flour = Ingredient(id: "flour", name: "plain flour", quantity: .exact(80, unit: .gram), sortIndex: 5)
        let cocoa = Ingredient(id: "cocoa", name: "cocoa powder", quantity: .exact(80, unit: .gram), sortIndex: 6)
        let soda = Ingredient(id: "soda", name: "bicarbonate of soda", quantity: .exact(1.3, unit: .gram), sortIndex: 7)
        let salt = Ingredient(id: "salt", name: "table salt", quantity: .exact(1.5, unit: .gram), sortIndex: 8)

        let batter = Workstream(id: "batter", name: "Batter", sortIndex: 0)
        let oven = Workstream(id: "oven", name: "Oven", sortIndex: 1)

        let preheat = Stage(
            id: "preheat",
            action: "Preheat",
            instruction: "Preheat the oven to 170°C and butter an 8-inch square tin.",
            completionCue: "Oven is hot and the tin is prepared",
            workstreamID: oven.id,
            resultLabel: "Prepared oven",
            temperature: .init(value: 170, unit: .celsius),
            sortIndex: 0
        )
        let melt = Stage(
            id: "melt",
            action: "Melt",
            instruction: "Melt the butter gently, then remove it from the heat.",
            completionCue: "Butter is liquid but not browned",
            workstreamID: batter.id,
            ingredientUses: [.init(ingredientID: butter.id, stateChange: "melted")],
            resultLabel: "Melted butter",
            duration: .init(minimumSeconds: 180),
            timers: [.init(id: "melt-timer", label: "Check butter", durationSeconds: 180)],
            heat: "low",
            sortIndex: 1
        )
        let mixWet = Stage(
            id: "mix-wet",
            action: "Mix",
            instruction: "Whisk the sugar, vanilla and espresso into the melted butter.",
            workstreamID: batter.id,
            dependencies: [melt.id],
            ingredientUses: [
                .init(ingredientID: sugar.id),
                .init(ingredientID: vanilla.id),
                .init(ingredientID: espresso.id)
            ],
            resultLabel: "Sweet coffee mixture",
            sortIndex: 2
        )
        let addEggs = Stage(
            id: "add-eggs",
            action: "Whisk",
            instruction: "Whisk in the eggs one at a time until glossy.",
            completionCue: "Mixture is smooth and glossy",
            workstreamID: batter.id,
            dependencies: [mixWet.id],
            ingredientUses: [.init(ingredientID: eggs.id)],
            resultLabel: "Wet mixture",
            sortIndex: 3
        )
        let fold = Stage(
            id: "fold",
            action: "Fold in",
            instruction: "Fold in the flour, cocoa, bicarbonate of soda and salt just until no dry streaks remain.",
            completionCue: "No pockets of dry flour remain",
            workstreamID: batter.id,
            dependencies: [addEggs.id],
            ingredientUses: [
                .init(ingredientID: flour.id),
                .init(ingredientID: cocoa.id),
                .init(ingredientID: soda.id),
                .init(ingredientID: salt.id)
            ],
            resultLabel: "Brownie batter",
            sortIndex: 4
        )
        let bake = Stage(
            id: "bake",
            action: "Bake",
            instruction: "Scrape the batter into the tin and bake until the centre is just set.",
            completionCue: "A skewer has moist crumbs rather than wet batter",
            workstreamID: oven.id,
            dependencies: [preheat.id, fold.id],
            resultLabel: "Baked brownies",
            duration: .init(minimumSeconds: 1_800, maximumSeconds: 2_400, isPassive: true),
            timers: [.init(id: "bake-timer", label: "Check brownies", durationSeconds: 1_800)],
            temperature: .init(value: 170, unit: .celsius),
            sortIndex: 5
        )

        return RecipeV1(
            id: "espresso-brownies-sample",
            title: "Espresso Brownies",
            summary: "Deep chocolate brownies sharpened with fresh espresso.",
            recipeYield: .init(servings: 9, label: "9 squares"),
            ingredients: [butter, sugar, vanilla, espresso, eggs, flour, cocoa, soda, salt],
            prepTasks: [
                .init(id: "prep-tin", instruction: "Butter and line an 8-inch square tin", ingredientIDs: [butter.id], sortIndex: 0)
            ],
            workstreams: [batter, oven],
            stages: [preheat, melt, mixWet, addEggs, fold, bake],
            uncertainties: [],
            provenance: .init(
                sourceType: .sample,
                title: "Bundled sample",
                cleanedText: "A demonstration recipe used to exercise serial, parallel and merge-stage layout."
            )
        )
    }()
}
