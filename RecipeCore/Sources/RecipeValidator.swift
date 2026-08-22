import Foundation

public struct RecipeValidationIssue: Codable, Hashable, Identifiable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case warning
        case error
    }

    public var id: String { "\(code):\(path)" }
    public let severity: Severity
    public let code: String
    public let path: String
    public let message: String

    public init(severity: Severity, code: String, path: String, message: String) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
    }
}

public struct RecipeValidationResult: Sendable {
    public let issues: [RecipeValidationIssue]
    public var isValid: Bool { !issues.contains { $0.severity == .error } }

    public init(issues: [RecipeValidationIssue]) {
        self.issues = issues
    }
}

public enum RecipeValidator {
    public static func validate(_ recipe: RecipeV1) -> RecipeValidationResult {
        var issues: [RecipeValidationIssue] = []
        if recipe.schemaVersion != 1 {
            issues.append(.init(severity: .error, code: "schema.version", path: "schemaVersion", message: "Only schema version 1 is supported."))
        }
        if recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .error, code: "recipe.title", path: "title", message: "Recipe title is required."))
        }
        if recipe.recipeYield.servings < 1 {
            issues.append(.init(severity: .error, code: "yield.servings", path: "yield.servings", message: "Servings must be at least one."))
        }

        let ingredientIDs = Set(recipe.ingredients.map(\.id))
        let stageIDs = Set(recipe.stages.map(\.id))
        let workstreamIDs = Set(recipe.workstreams.map(\.id))
        issues += duplicateIssues(recipe.ingredients.map(\.id), path: "ingredients", code: "ingredient.duplicate")
        issues += duplicateIssues(recipe.stages.map(\.id), path: "stages", code: "stage.duplicate")
        issues += duplicateIssues(recipe.workstreams.map(\.id), path: "workstreams", code: "workstream.duplicate")

        for task in recipe.prepTasks {
            for ingredientID in task.ingredientIDs where !ingredientIDs.contains(ingredientID) {
                issues.append(.init(severity: .error, code: "prep.ingredient", path: "prepTasks.\(task.id)", message: "Prep task references unknown ingredient \(ingredientID)."))
            }
        }

        var usedIngredientIDs: Set<String> = []
        for stage in recipe.stages {
            if let workstreamID = stage.workstreamID, !workstreamIDs.contains(workstreamID) {
                issues.append(.init(severity: .error, code: "stage.workstream", path: "stages.\(stage.id)", message: "Stage references unknown workstream \(workstreamID)."))
            }
            for dependency in stage.dependencies {
                if dependency == stage.id {
                    issues.append(.init(severity: .error, code: "stage.selfDependency", path: "stages.\(stage.id).dependencies", message: "A stage cannot depend on itself."))
                } else if !stageIDs.contains(dependency) {
                    issues.append(.init(severity: .error, code: "stage.dependency", path: "stages.\(stage.id).dependencies", message: "Stage references unknown dependency \(dependency)."))
                }
            }
            if let duration = stage.duration {
                if duration.minimumSeconds < 0 || (duration.maximumSeconds.map { $0 < duration.minimumSeconds } ?? false) {
                    issues.append(.init(severity: .error, code: "stage.duration", path: "stages.\(stage.id).duration", message: "Stage duration range is invalid."))
                }
            }
            for timer in stage.timers where timer.durationSeconds <= 0 {
                issues.append(.init(severity: .error, code: "stage.timer", path: "stages.\(stage.id).timers", message: "Timer duration must be positive."))
            }
            for use in stage.ingredientUses {
                guard ingredientIDs.contains(use.ingredientID) else {
                    issues.append(.init(severity: .error, code: "stage.ingredient", path: "stages.\(stage.id).ingredientUses", message: "Stage references unknown ingredient \(use.ingredientID)."))
                    continue
                }
                usedIngredientIDs.insert(use.ingredientID)
            }
            if stage.completionCue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               stage.resultLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               !stage.ingredientUses.contains(where: { $0.stateChange?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) {
                issues.append(.init(
                    severity: .warning,
                    code: "stage.stateChange",
                    path: "stages.\(stage.id)",
                    message: "Stage has no explicit completion cue, intermediate result, or ingredient state change."
                ))
            }
        }

        issues += cycleIssues(recipe.stages)
        issues += allocationIssues(recipe)

        let uncertainIngredients = Set(recipe.uncertainties.filter { !$0.isResolved }.flatMap(\.ingredientIDs))
        for ingredientID in ingredientIDs.subtracting(usedIngredientIDs).subtracting(uncertainIngredients).sorted() {
            issues.append(.init(
                severity: .warning,
                code: "ingredient.unused",
                path: "ingredients.\(ingredientID)",
                message: "Ingredient is not assigned to a stage and has no unresolved uncertainty."
            ))
        }

        for uncertainty in recipe.uncertainties {
            for ingredientID in uncertainty.ingredientIDs where !ingredientIDs.contains(ingredientID) {
                issues.append(.init(severity: .error, code: "uncertainty.ingredient", path: "uncertainties.\(uncertainty.id)", message: "Uncertainty references unknown ingredient \(ingredientID)."))
            }
            for stageID in uncertainty.stageIDs where !stageIDs.contains(stageID) {
                issues.append(.init(severity: .error, code: "uncertainty.stage", path: "uncertainties.\(uncertainty.id)", message: "Uncertainty references unknown stage \(stageID)."))
            }
        }
        return .init(issues: issues)
    }

    private static func duplicateIssues(_ values: [String], path: String, code: String) -> [RecipeValidationIssue] {
        let duplicates = Dictionary(grouping: values, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        return duplicates.map {
            .init(severity: .error, code: code, path: path, message: "Duplicate identifier \($0).")
        }
    }

    private static func cycleIssues(_ stages: [Stage]) -> [RecipeValidationIssue] {
        let dependencies = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0.dependencies) })
        var visiting: Set<String> = []
        var visited: Set<String> = []
        var cycleNodes: Set<String> = []

        func visit(_ id: String) {
            if visiting.contains(id) {
                cycleNodes.insert(id)
                return
            }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            for dependency in dependencies[id] ?? [] {
                visit(dependency)
                if cycleNodes.contains(dependency) { cycleNodes.insert(id) }
            }
            visiting.remove(id)
            visited.insert(id)
        }

        for stage in stages { visit(stage.id) }
        guard !cycleNodes.isEmpty else { return [] }
        return [.init(
            severity: .error,
            code: "graph.cycle",
            path: "stages",
            message: "Stage dependencies contain a cycle involving: \(cycleNodes.sorted().joined(separator: ", "))."
        )]
    }

    private static func allocationIssues(_ recipe: RecipeV1) -> [RecipeValidationIssue] {
        var issues: [RecipeValidationIssue] = []
        for ingredient in recipe.ingredients {
            guard let sourceQuantity = ingredient.quantity, sourceQuantity.kind == .exact, let sourceValue = sourceQuantity.value else { continue }
            let allocations = recipe.stages.flatMap(\.ingredientUses).filter { $0.ingredientID == ingredient.id }.compactMap(\.quantity)
            guard !allocations.isEmpty else { continue }
            var total: Decimal = 0
            var comparable = true
            for allocation in allocations {
                guard allocation.kind == .exact, let value = allocation.value else {
                    comparable = false
                    break
                }
                guard let converted = try? CulinaryUnits.converted(value, from: allocation.unit, to: sourceQuantity.unit) else {
                    comparable = false
                    break
                }
                total += converted
            }
            if comparable, total > sourceValue * Decimal(string: "1.001")! {
                issues.append(.init(
                    severity: .error,
                    code: "ingredient.overAllocated",
                    path: "ingredients.\(ingredient.id)",
                    message: "Stage allocations exceed the source quantity for \(ingredient.name)."
                ))
            } else if comparable, allocations.count == recipe.stages.flatMap(\.ingredientUses).filter({ $0.ingredientID == ingredient.id }).count,
                      total < sourceValue * Decimal(string: "0.999")! {
                issues.append(.init(
                    severity: .warning,
                    code: "ingredient.underAllocated",
                    path: "ingredients.\(ingredient.id)",
                    message: "Explicit stage allocations do not account for the full source quantity of \(ingredient.name)."
                ))
            }
        }
        return issues
    }
}
