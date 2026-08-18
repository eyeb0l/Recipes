import XCTest
@testable import RecipeCore

final class RecipeCoreTests: XCTestCase {
    func testSampleRecipeValidatesAndRoundTrips() throws {
        let recipe = SampleRecipe.espressoBrownies
        let result = RecipeValidator.validate(recipe)
        XCTAssertTrue(result.isValid, result.issues.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(result.issues.isEmpty, result.issues.map(\.message).joined(separator: "\n"))

        let data = try RecipeCoding.encoder.encode(recipe)
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(canonical.keys.contains("summary"))
        let stages = try XCTUnwrap(canonical["stages"] as? [[String: Any]])
        XCTAssertTrue(stages.allSatisfy { $0.keys.contains("notes") && $0.keys.contains("duration") })
        let decoded = try RecipeCoding.decoder.decode(RecipeV1.self, from: data)
        XCTAssertEqual(decoded, recipe)
    }

    func testPreviewSchemaMigratesAndFutureVersionIsRejected() throws {
        let preview: [String: Any] = [
            "id": "preview", "title": "Preview soup", "servings": 2,
            "ingredients": [["id": "water", "name": "water", "scalable": true, "sortIndex": 0]],
            "stages": [[
                "id": "boil", "action": "Boil", "instruction": "Bring the water to a boil.",
                "completionCue": "Water is boiling", "ingredientUses": [["ingredientID": "water"]]
            ]]
        ]
        let recipe = try RecipeSchemaMigrator.decodeAndMigrate(JSONSerialization.data(withJSONObject: preview))
        XCTAssertEqual(recipe.schemaVersion, 1)
        XCTAssertEqual(recipe.recipeYield.servings, 2)
        XCTAssertEqual(recipe.stages.first?.sortIndex, 0)

        var future = preview
        future["schemaVersion"] = 99
        XCTAssertThrowsError(try RecipeSchemaMigrator.decodeAndMigrate(JSONSerialization.data(withJSONObject: future))) {
            XCTAssertEqual($0 as? RecipeSchemaMigrationError, .unsupportedVersion(99))
        }
    }

    func testValidatorDetectsCycleAndDanglingReference() {
        var recipe = SampleRecipe.espressoBrownies
        recipe.stages[0].dependencies = [recipe.stages.last!.id, "missing-stage"]
        let result = RecipeValidator.validate(recipe)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.code == "graph.cycle" })
        XCTAssertTrue(result.issues.contains { $0.code == "stage.dependency" })
    }

    func testUnusedIngredientMustHaveUncertainty() {
        var recipe = SampleRecipe.espressoBrownies
        recipe.ingredients.append(.init(id: "mystery", name: "mystery spice", sortIndex: 99))
        var result = RecipeValidator.validate(recipe)
        XCTAssertTrue(result.issues.contains { $0.code == "ingredient.unused" })

        recipe.uncertainties.append(.init(
            kind: .missingPlacement,
            message: "The source does not say when to add the mystery spice.",
            ingredientIDs: ["mystery"]
        ))
        result = RecipeValidator.validate(recipe)
        XCTAssertFalse(result.issues.contains { $0.code == "ingredient.unused" })
    }

    func testDividedIngredientAllocationsAndMissingStateChangeAreReported() {
        let oil = Ingredient(id: "oil", name: "oil", quantity: .exact(100, unit: .milliliter), sortIndex: 0)
        let first = Stage(id: "first", action: "Add", instruction: "Add some oil.", ingredientUses: [.init(ingredientID: oil.id, quantity: .exact(40, unit: .milliliter))], sortIndex: 0)
        let second = Stage(id: "second", action: "Finish", instruction: "Add the remaining oil.", dependencies: [first.id], ingredientUses: [.init(ingredientID: oil.id, quantity: .exact(40, unit: .milliliter))], sortIndex: 1)
        var recipe = RecipeV1(title: "Divided oil", recipeYield: .init(servings: 2), ingredients: [oil], stages: [first, second], provenance: .init(sourceType: .manual))
        var issues = RecipeValidator.validate(recipe).issues
        XCTAssertTrue(issues.contains { $0.code == "ingredient.underAllocated" })
        XCTAssertTrue(issues.contains { $0.code == "stage.stateChange" })

        recipe.stages[0].ingredientUses[0].quantity = .exact(60, unit: .milliliter)
        recipe.stages[0].ingredientUses[0].stateChange = "reserved and divided"
        recipe.stages[0].resultLabel = "Reserved oil"
        recipe.stages[1].completionCue = "All oil is incorporated"
        issues = RecipeValidator.validate(recipe).issues
        XCTAssertFalse(issues.contains { $0.code == "ingredient.underAllocated" })
        XCTAssertFalse(issues.contains { $0.code == "stage.stateChange" })

        recipe.stages[1].ingredientUses[0].quantity = .exact(60, unit: .milliliter)
        XCTAssertTrue(RecipeValidator.validate(recipe).issues.contains { $0.code == "ingredient.overAllocated" })
    }

    func testLayoutUsesTopologicalColumnsAndIngredientLineage() throws {
        let recipe = SampleRecipe.espressoBrownies
        let layout = try TimelineLayoutEngine.makeLayout(for: recipe)
        let placements = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.stageID, $0) })

        XCTAssertEqual(placements["preheat"]?.column, 0)
        XCTAssertTrue(placements["preheat"]?.isGlobal == true)
        XCTAssertEqual(placements["melt"]?.column, 0)
        XCTAssertEqual(placements["bake"]?.column, 4)
        XCTAssertEqual(Set(placements["bake"]?.ingredientLineage ?? []), Set(recipe.ingredients.map(\.id)))
    }

    func testParallelStagesShareColumnWithoutColliding() throws {
        let sauce = Ingredient(id: "tomatoes", name: "tomatoes", sortIndex: 0)
        let pasta = Ingredient(id: "pasta", name: "pasta", sortIndex: 1)
        let sauceStage = Stage(id: "sauce", action: "Simmer", instruction: "Simmer sauce", ingredientUses: [.init(ingredientID: sauce.id)], sortIndex: 0)
        let pastaStage = Stage(id: "pasta-stage", action: "Boil", instruction: "Boil pasta", ingredientUses: [.init(ingredientID: pasta.id)], sortIndex: 1)
        let merge = Stage(id: "merge", action: "Combine", instruction: "Combine pasta and sauce", dependencies: [sauceStage.id, pastaStage.id], sortIndex: 2)
        let recipe = RecipeV1(
            title: "Parallel pasta",
            recipeYield: .init(servings: 2),
            ingredients: [sauce, pasta],
            stages: [sauceStage, pastaStage, merge],
            provenance: .init(sourceType: .manual)
        )

        let layout = try TimelineLayoutEngine.makeLayout(for: recipe)
        let placements = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.stageID, $0) })
        XCTAssertEqual(placements[sauceStage.id]?.column, 0)
        XCTAssertEqual(placements[pastaStage.id]?.column, 0)
        XCTAssertEqual(placements[sauceStage.id]?.subcolumn, 0)
        XCTAssertEqual(placements[pastaStage.id]?.subcolumn, 0)
        XCTAssertEqual(placements[merge.id]?.column, 1)
        XCTAssertEqual(placements[merge.id]?.startRow, 0)
        XCTAssertEqual(placements[merge.id]?.endRow, 1)
    }

    func testLayoutOutputIsDeterministicForLongParallelMergeRecipe() throws {
        var recipe = SampleRecipe.espressoBrownies
        for index in 0..<24 {
            let prior = recipe.stages.last!.id
            recipe.stages.append(.init(
                id: "rest-\(index)", action: "Rest", instruction: "Rest stage \(index)", completionCue: "Rest complete",
                workstreamID: recipe.workstreams.first!.id, dependencies: [prior], resultLabel: "Rested \(index)", sortIndex: recipe.stages.count
            ))
        }
        let first = try TimelineLayoutEngine.makeLayout(for: recipe)
        for _ in 0..<20 { XCTAssertEqual(try TimelineLayoutEngine.makeLayout(for: recipe), first) }
        XCTAssertEqual(first.rowCount, recipe.ingredients.count)
        XCTAssertEqual(first.columnCount, 29)
    }

    func testServingScalingAndUnitConversion() throws {
        let quantity = CulinaryQuantity.exact(500, unit: .gram)
        let scaled = quantity.scaled(by: 2).converted(for: .imperial)
        XCTAssertEqual(scaled.unit, .pound)
        XCTAssertDecimalEqual(try CulinaryUnits.converted(scaled.value!, from: .pound, to: .gram), 1_000, accuracy: Decimal(string: "0.001")!)

        let qualitative = CulinaryQuantity.qualitative("to taste")
        XCTAssertEqual(qualitative.scaled(by: 8).displayString(), "to taste")

        XCTAssertEqual(CulinaryQuantity.range(0.25, 0.5, unit: .cup).displayString(), "¼–½ cup")
        XCTAssertThrowsError(try CulinaryUnits.converted(100, from: .gram, to: .cup))
        XCTAssertEqual(CookingTemperature(value: 180, unit: .celsius).converted(for: .imperial).value, 356)
    }

    func testCookSessionSupportsParallelReadinessAndTimerRecovery() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CookSession-\(UUID().uuidString).json")
        let store = CookSessionStore(fileURL: url)
        var recipe = SampleRecipe.espressoBrownies
        let meltIndex = try XCTUnwrap(recipe.stages.firstIndex { $0.id == "melt" })
        recipe.stages[meltIndex].timers.append(.init(id: "stir-timer", label: "Stir butter", durationSeconds: 90))
        let start = Date(timeIntervalSince1970: 1_000)
        var session = try await store.createSession(for: recipe, date: start)
        XCTAssertEqual(Set(session.readyStageIDs), Set(["preheat", "melt"]))

        do {
            _ = try await store.complete(stageID: "mix-wet", sessionID: session.id, date: start)
            XCTFail("A dependency-blocked stage must not be completed")
        } catch let error as CookSessionError {
            XCTAssertEqual(error, .blockedStage)
        }

        do {
            _ = try await store.complete(stageID: "missing", sessionID: session.id, date: start)
            XCTFail("An unknown stage must not be completed")
        } catch let error as CookSessionError {
            XCTAssertEqual(error, .unknownStage)
        }

        session = try await store.toggleTimer(
            sessionID: session.id,
            stageID: "melt",
            timer: recipe.stages.first { $0.id == "melt" }!.timers[0],
            date: start
        )
        session = try await store.toggleTimer(
            sessionID: session.id,
            stageID: "melt",
            timer: recipe.stages[meltIndex].timers[1],
            date: start
        )
        XCTAssertEqual(session.runningTimerCount, 2)

        session = try await store.reconcileTimers(sessionID: session.id, date: start.addingTimeInterval(181))
        XCTAssertTrue(session.timers.allSatisfy { $0.status == .finished })
        session = try await store.toggleTimer(
            sessionID: session.id,
            stageID: "melt",
            timer: recipe.stages[meltIndex].timers[0],
            date: start.addingTimeInterval(182)
        )
        session = try await store.cancelTimer(timerID: "melt:melt-timer", sessionID: session.id, date: start.addingTimeInterval(183))
        XCTAssertEqual(session.timers.first { $0.id == "melt:melt-timer" }?.status, .cancelled)
        session = try await store.toggleTimer(
            sessionID: session.id,
            stageID: "melt",
            timer: recipe.stages[meltIndex].timers[0],
            date: start.addingTimeInterval(184)
        )
        XCTAssertEqual(session.timers.first { $0.id == "melt:melt-timer" }?.status, .running)
        session = try await store.complete(stageID: "melt", sessionID: session.id, date: start.addingTimeInterval(185))
        XCTAssertTrue(session.readyStageIDs.contains("mix-wet"))

        let recoveredStore = CookSessionStore(fileURL: url)
        let recovered = try await recoveredStore.session(id: session.id)
        XCTAssertEqual(recovered, session)
    }
}

private extension XCTestCase {
    func XCTAssertDecimalEqual(_ expression1: Decimal, _ expression2: Decimal, accuracy: Decimal, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(expression1 - expression2), accuracy, file: file, line: line)
    }
}
