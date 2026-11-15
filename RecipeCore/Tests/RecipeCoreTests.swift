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
        XCTAssertEqual(placements[sauceStage.id]?.subcolumnCount, 1)
        XCTAssertEqual(placements[pastaStage.id]?.subcolumnCount, 1)
        XCTAssertEqual(placements[merge.id]?.column, 1)
        XCTAssertEqual(placements[merge.id]?.startRow, 0)
        XCTAssertEqual(placements[merge.id]?.endRow, 1)
    }

    func testCollisionLaneCountsAreScopedToConnectedRowIntervals() throws {
        let first = Ingredient(id: "first-ingredient", name: "first", sortIndex: 0)
        let second = Ingredient(id: "second-ingredient", name: "second", sortIndex: 1)
        let third = Ingredient(id: "third-ingredient", name: "third", sortIndex: 2)
        let stages = [
            Stage(id: "a", action: "A", instruction: "Use first in A", ingredientUses: [.init(ingredientID: first.id)], sortIndex: 0),
            Stage(id: "b", action: "B", instruction: "Use first in B", ingredientUses: [.init(ingredientID: first.id)], sortIndex: 1),
            Stage(id: "c", action: "C", instruction: "Use second", ingredientUses: [.init(ingredientID: second.id)], sortIndex: 2),
            Stage(id: "d", action: "D", instruction: "Use third", ingredientUses: [.init(ingredientID: third.id)], sortIndex: 3),
        ]
        let recipe = RecipeV1(
            title: "Collision groups",
            recipeYield: .init(servings: 1),
            ingredients: [first, second, third],
            stages: stages,
            provenance: .init(sourceType: .manual)
        )

        let placements = Dictionary(uniqueKeysWithValues: try TimelineLayoutEngine.makeLayout(for: recipe).placements.map { ($0.stageID, $0) })
        XCTAssertEqual(placements["a"]?.subcolumn, 0)
        XCTAssertEqual(placements["b"]?.subcolumn, 1)
        XCTAssertEqual(placements["a"]?.subcolumnCount, 2)
        XCTAssertEqual(placements["b"]?.subcolumnCount, 2)
        XCTAssertEqual(placements["c"]?.subcolumn, 0)
        XCTAssertEqual(placements["c"]?.subcolumnCount, 1)
        XCTAssertEqual(placements["d"]?.subcolumn, 0)
        XCTAssertEqual(placements["d"]?.subcolumnCount, 1)
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

    func testInvalidSubOneServingYieldResolvesFromUnambiguousSourceLabel() throws {
        let malformed = RecipeYield(servings: Decimal(string: "0.004")!, label: "4 servings")
        XCTAssertEqual(malformed.resolvedServings, 4)

        let ingredient = Ingredient(
            name: "Italian sausage",
            quantity: .exact(1, unit: .pound),
            sortIndex: 0
        )
        XCTAssertEqual(
            ingredient.displayQuantity(
                servings: malformed.resolvedServings,
                originalServings: malformed.resolvedServings,
                units: .metric
            ),
            "453.59 g"
        )

        var recipe = SampleRecipe.espressoBrownies
        recipe.recipeYield = malformed
        let validation = RecipeValidator.validate(recipe)
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.issues.contains { $0.code == "yield.servings" })

        let repaired = try RecipeSchemaMigrator.decodeAndMigrate(RecipeCoding.encoder.encode(recipe))
        XCTAssertEqual(repaired.recipeYield.servings, 4)
        XCTAssertTrue(RecipeValidator.validate(repaired).isValid)
    }

    func testInvalidServingYieldFallsBackSafelyWhenSourceLabelIsAmbiguous() {
        XCTAssertEqual(RecipeYield(servings: 0, label: nil).resolvedServings, 1)
        XCTAssertEqual(RecipeYield(servings: Decimal(string: "0.004")!, label: "Serves 4–6").resolvedServings, 1)
        XCTAssertEqual(RecipeYield(servings: Decimal(string: "2.5")!, label: "2.5 servings").resolvedServings, Decimal(string: "2.5")!)
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

    func testEstimatedTotalTimeFollowsTheCriticalPathAcrossParallelWork() {
        let recipe = SampleRecipe.espressoBrownies
        // Melting (3 min) leads to the bake (30 min); preheating runs in parallel and adds nothing.
        XCTAssertEqual(recipe.estimatedTotalSeconds, 1_980)
        XCTAssertEqual(RecipeDurationFormatter.string(seconds: 1_980), "33 min")
        XCTAssertEqual(RecipeDurationFormatter.string(seconds: 4_800), "1 hr 20 min")
        XCTAssertEqual(RecipeDurationFormatter.string(seconds: 7_200), "2 hr")

        var untimed = recipe
        for index in untimed.stages.indices {
            untimed.stages[index].duration = nil
            untimed.stages[index].timers = []
        }
        XCTAssertNil(untimed.estimatedTotalSeconds)
    }

    func testRemovingAnIngredientClearsEveryReference() {
        var recipe = SampleRecipe.espressoBrownies
        recipe.uncertainties.append(.init(kind: .ambiguousQuantity, message: "The butter amount is unclear.", ingredientIDs: ["butter"]))
        recipe.removeIngredient(id: "butter")

        XCTAssertFalse(recipe.ingredients.contains { $0.id == "butter" })
        XCTAssertEqual(recipe.ingredients.map(\.sortIndex), Array(0..<recipe.ingredients.count))
        XCTAssertFalse(recipe.stages.flatMap(\.ingredientUses).contains { $0.ingredientID == "butter" })
        XCTAssertFalse(recipe.prepTasks.flatMap(\.ingredientIDs).contains("butter"))
        XCTAssertFalse(recipe.uncertainties.flatMap(\.ingredientIDs).contains("butter"))
        XCTAssertTrue(RecipeValidator.validate(recipe).isValid, RecipeValidator.validate(recipe).issues.map(\.message).joined(separator: "\n"))
    }

    func testRemovingAStageReconnectsItsFollowers() throws {
        var recipe = SampleRecipe.espressoBrownies
        recipe.removeStage(id: "fold")

        let bake = try XCTUnwrap(recipe.stages.first { $0.id == "bake" })
        XCTAssertEqual(Set(bake.dependencies), Set(["preheat", "add-eggs"]))
        XCTAssertEqual(recipe.sortedStages.map(\.sortIndex), Array(0..<recipe.stages.count))
        XCTAssertTrue(RecipeValidator.validate(recipe).isValid, RecipeValidator.validate(recipe).issues.map(\.message).joined(separator: "\n"))
    }

    func testResumingACookSessionKeepsProgressAndAdoptsNewScaling() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CookSession-\(UUID().uuidString).json")
        let store = CookSessionStore(fileURL: url)
        let recipe = SampleRecipe.espressoBrownies
        let first = try await store.createSession(for: recipe, servings: 9, unitSystem: .metric)
        _ = try await store.complete(stageID: "preheat", sessionID: first.id)

        let resumed = try await store.createSession(for: recipe, servings: 18, unitSystem: .imperial)
        XCTAssertEqual(resumed.id, first.id)
        XCTAssertEqual(resumed.completedStageIDs, ["preheat"])
        XCTAssertEqual(resumed.servings, 18)
        XCTAssertEqual(resumed.unitSystem, .imperial)
        XCTAssertEqual(resumed.progress, 1.0 / 6.0, accuracy: 0.000_1)
    }

    func testCookAmountsComeFromTheSnapshotTakenWhenCookingStarted() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CookSession-\(UUID().uuidString).json")
        let store = CookSessionStore(fileURL: url)
        var recipe = SampleRecipe.espressoBrownies
        let session = try await store.createSession(for: recipe, servings: 18, unitSystem: .metric)

        // Editing the recipe mid-cook must not change the amounts shown beside the saved instructions.
        let butter = try XCTUnwrap(recipe.ingredients.firstIndex { $0.id == "butter" })
        recipe.ingredients[butter].name = "olive oil"
        recipe.ingredients[butter].quantity = .exact(500, unit: .gram)
        let resumed = try await store.createSession(for: recipe, servings: 18, unitSystem: .metric)
        XCTAssertEqual(resumed.id, session.id)

        let melt = try XCTUnwrap(resumed.stages.first { $0.id == "melt" })
        XCTAssertEqual(resumed.ingredientLines(for: melt), ["230 g unsalted butter"])

        var legacy = melt
        legacy.ingredients = nil
        XCTAssertEqual(resumed.ingredientLines(for: legacy), ["unsalted butter"])
    }

    func testTappingAnExpiredButUnreconciledTimerRestartsIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CookSession-\(UUID().uuidString).json")
        let store = CookSessionStore(fileURL: url)
        let recipe = SampleRecipe.espressoBrownies
        let timer = try XCTUnwrap(recipe.stages.first { $0.id == "melt" }?.timers.first)
        let start = Date(timeIntervalSince1970: 10_000)
        var session = try await store.createSession(for: recipe, date: start)
        session = try await store.toggleTimer(sessionID: session.id, stageID: "melt", timer: timer, date: start)

        let afterDeadline = start.addingTimeInterval(TimeInterval(timer.durationSeconds + 5))
        session = try await store.toggleTimer(sessionID: session.id, stageID: "melt", timer: timer, date: afterDeadline)
        let state = try XCTUnwrap(session.timers.first)
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.endDate, afterDeadline.addingTimeInterval(TimeInterval(timer.durationSeconds)))
    }

    func testEndingASessionStopsItsTimers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CookSession-\(UUID().uuidString).json")
        let store = CookSessionStore(fileURL: url)
        let recipe = SampleRecipe.espressoBrownies
        let timer = try XCTUnwrap(recipe.stages.first { $0.id == "melt" }?.timers.first)
        let session = try await store.createSession(for: recipe)
        _ = try await store.toggleTimer(sessionID: session.id, stageID: "melt", timer: timer)

        try await store.end(sessionID: session.id)
        let fetched = try await store.session(id: session.id)
        let ended = try XCTUnwrap(fetched)
        XCTAssertNotNil(ended.endedAt)
        XCTAssertEqual(ended.runningTimerCount, 0)
        XCTAssertTrue(ended.timers.allSatisfy { $0.status == .cancelled && $0.endDate == nil })
        let active = try await store.activeSession(for: recipe.id)
        XCTAssertNil(active)

        // A timer intent queued from the Live Activity before the end must not restart anything.
        do {
            _ = try await store.toggleTimer(sessionID: session.id, stageID: "melt", timer: timer)
            XCTFail("An ended session must reject timer changes")
        } catch let error as CookSessionError {
            XCTAssertEqual(error, .sessionEnded)
        }
        let afterIntent = try await store.session(id: session.id)
        XCTAssertEqual(afterIntent?.runningTimerCount, 0)
    }

    func testCookSessionsSavedBeforeScalingWasStoredStillDecode() throws {
        let session = CookSession(recipe: SampleRecipe.espressoBrownies, servings: 4, unitSystem: .metric)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object.removeValue(forKey: "servings")
        object.removeValue(forKey: "unitSystem")
        let legacy = try JSONDecoder().decode(CookSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.servings)
        XCTAssertNil(legacy.unitSystem)
        XCTAssertEqual(legacy.stages, session.stages)
    }
}

private extension XCTestCase {
    func XCTAssertDecimalEqual(_ expression1: Decimal, _ expression2: Decimal, accuracy: Decimal, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(expression1 - expression2), accuracy, file: file, line: line)
    }
}
