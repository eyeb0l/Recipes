import Foundation

public struct RecipeV1: Codable, Hashable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var summary: String?
    public var recipeYield: RecipeYield
    public var ingredients: [Ingredient]
    public var prepTasks: [PrepTask]
    public var workstreams: [Workstream]
    public var stages: [Stage]
    public var uncertainties: [RecipeUncertainty]
    public var provenance: RecipeProvenance

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, summary
        case recipeYield = "yield"
        case ingredients, prepTasks, workstreams, stages, uncertainties, provenance
    }

    public init(
        schemaVersion: Int = 1,
        id: String = UUID().uuidString,
        title: String,
        summary: String? = nil,
        recipeYield: RecipeYield,
        ingredients: [Ingredient],
        prepTasks: [PrepTask] = [],
        workstreams: [Workstream] = [],
        stages: [Stage],
        uncertainties: [RecipeUncertainty] = [],
        provenance: RecipeProvenance
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.summary = summary
        self.recipeYield = recipeYield
        self.ingredients = ingredients
        self.prepTasks = prepTasks
        self.workstreams = workstreams
        self.stages = stages
        self.uncertainties = uncertainties
        self.provenance = provenance
    }

    public var sortedIngredients: [Ingredient] {
        ingredients.sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }
    }

    public var sortedStages: [Stage] {
        stages.sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }
    }
}

public struct RecipeYield: Codable, Hashable, Sendable {
    public var servings: Decimal
    public var label: String?

    public init(servings: Decimal, label: String? = nil) {
        self.servings = servings
        self.label = label
    }

    /// Returns a usable serving count for scaling and display.
    ///
    /// Earlier provider output could contain a unit-scaled value such as
    /// `0.004` while retaining the source label `"4 servings"`. A serving
    /// count below one cannot be represented by the app's serving controls,
    /// so recover a single, unambiguous count from the source label. If the
    /// label is absent or ambiguous, one serving is the safe neutral base.
    public var resolvedServings: Decimal {
        guard servings < 1 else { return servings }
        guard let label, let labelServings = Self.unambiguousServingCount(in: label) else { return 1 }
        return labelServings
    }

    private static func unambiguousServingCount(in label: String) -> Decimal? {
        let tokens = label.split { character in
            !character.isNumber && character != "." && character != ","
        }
        let candidates = tokens.compactMap { token -> Decimal? in
            Decimal(string: token.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
        }
        guard candidates.count == 1, let candidate = candidates.first, candidate >= 1, candidate <= 100 else {
            return nil
        }
        return candidate
    }
}

public enum QuantityKind: String, Codable, CaseIterable, Sendable {
    case exact
    case range
    case text
}

public enum UnitID: String, Codable, CaseIterable, Sendable {
    case none
    case gram
    case kilogram
    case ounce
    case pound
    case milliliter
    case liter
    case teaspoon
    case tablespoon
    case cup
    /// A US fluid ounce.
    case fluidOunce
    /// A US pint.
    case pint
    /// A UK imperial fluid ounce, 28.4130625 ml.
    case imperialFluidOunce
    /// A UK imperial pint of 20 imperial fluid ounces, 568.26125 ml.
    case imperialPint
    case celsius
    case fahrenheit
    case count
    case pinch
    case clove
    case slice
    case can
    case package
    case bunch
    case sprig
    case shot
}

public struct CulinaryQuantity: Codable, Hashable, Sendable {
    public var kind: QuantityKind
    public var value: Decimal?
    public var lower: Decimal?
    public var upper: Decimal?
    public var text: String?
    public var unit: UnitID
    public var originalText: String?

    public init(
        kind: QuantityKind,
        value: Decimal? = nil,
        lower: Decimal? = nil,
        upper: Decimal? = nil,
        text: String? = nil,
        unit: UnitID = .none,
        originalText: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.lower = lower
        self.upper = upper
        self.text = text
        self.unit = unit
        self.originalText = originalText
    }

    public static func exact(_ value: Decimal, unit: UnitID, originalText: String? = nil) -> Self {
        .init(kind: .exact, value: value, unit: unit, originalText: originalText)
    }

    public static func range(_ lower: Decimal, _ upper: Decimal, unit: UnitID, originalText: String? = nil) -> Self {
        .init(kind: .range, lower: lower, upper: upper, unit: unit, originalText: originalText)
    }

    public static func qualitative(_ text: String, originalText: String? = nil) -> Self {
        .init(kind: .text, text: text, unit: .none, originalText: originalText)
    }
}

public struct Ingredient: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var quantity: CulinaryQuantity?
    public var scalable: Bool
    public var notes: String?
    public var sortIndex: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        quantity: CulinaryQuantity? = nil,
        scalable: Bool = true,
        notes: String? = nil,
        sortIndex: Int
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.scalable = scalable
        self.notes = notes
        self.sortIndex = sortIndex
    }
}

public struct PrepTask: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var instruction: String
    public var ingredientIDs: [String]
    public var isOptional: Bool
    public var sortIndex: Int

    public init(
        id: String = UUID().uuidString,
        instruction: String,
        ingredientIDs: [String] = [],
        isOptional: Bool = false,
        sortIndex: Int
    ) {
        self.id = id
        self.instruction = instruction
        self.ingredientIDs = ingredientIDs
        self.isOptional = isOptional
        self.sortIndex = sortIndex
    }
}

public struct Workstream: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var sortIndex: Int

    public init(id: String = UUID().uuidString, name: String, sortIndex: Int) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }
}

public struct IngredientUse: Codable, Hashable, Sendable {
    public var ingredientID: String
    public var quantity: CulinaryQuantity?
    public var stateChange: String?

    public init(ingredientID: String, quantity: CulinaryQuantity? = nil, stateChange: String? = nil) {
        self.ingredientID = ingredientID
        self.quantity = quantity
        self.stateChange = stateChange
    }
}

public struct StageDuration: Codable, Hashable, Sendable {
    public var minimumSeconds: Int
    public var maximumSeconds: Int?
    public var isPassive: Bool

    public init(minimumSeconds: Int, maximumSeconds: Int? = nil, isPassive: Bool = false) {
        self.minimumSeconds = minimumSeconds
        self.maximumSeconds = maximumSeconds
        self.isPassive = isPassive
    }
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius
    case fahrenheit
}

public struct CookingTemperature: Codable, Hashable, Sendable {
    public var value: Decimal
    public var unit: TemperatureUnit

    public init(value: Decimal, unit: TemperatureUnit) {
        self.value = value
        self.unit = unit
    }
}

public struct StageTimer: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var durationSeconds: Int

    public init(id: String = UUID().uuidString, label: String, durationSeconds: Int) {
        self.id = id
        self.label = label
        self.durationSeconds = durationSeconds
    }
}

public struct Stage: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var action: String
    public var instruction: String
    public var completionCue: String?
    public var workstreamID: String?
    public var dependencies: [String]
    public var ingredientUses: [IngredientUse]
    public var resultLabel: String?
    public var duration: StageDuration?
    public var timers: [StageTimer]
    public var heat: String?
    public var temperature: CookingTemperature?
    public var notes: String?
    public var sortIndex: Int

    public init(
        id: String = UUID().uuidString,
        action: String,
        instruction: String,
        completionCue: String? = nil,
        workstreamID: String? = nil,
        dependencies: [String] = [],
        ingredientUses: [IngredientUse] = [],
        resultLabel: String? = nil,
        duration: StageDuration? = nil,
        timers: [StageTimer] = [],
        heat: String? = nil,
        temperature: CookingTemperature? = nil,
        notes: String? = nil,
        sortIndex: Int
    ) {
        self.id = id
        self.action = action
        self.instruction = instruction
        self.completionCue = completionCue
        self.workstreamID = workstreamID
        self.dependencies = dependencies
        self.ingredientUses = ingredientUses
        self.resultLabel = resultLabel
        self.duration = duration
        self.timers = timers
        self.heat = heat
        self.temperature = temperature
        self.notes = notes
        self.sortIndex = sortIndex
    }
}

public enum UncertaintyKind: String, Codable, CaseIterable, Sendable {
    case missingPlacement
    case conflictingSource
    case ambiguousQuantity
    case ambiguousTiming
    case ambiguousState
    case other
}

public enum UncertaintySeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case critical
}

public struct RecipeUncertainty: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: UncertaintyKind
    public var severity: UncertaintySeverity
    public var message: String
    public var ingredientIDs: [String]
    public var stageIDs: [String]
    public var sourceEvidence: String?
    public var isResolved: Bool

    public init(
        id: String = UUID().uuidString,
        kind: UncertaintyKind,
        severity: UncertaintySeverity = .warning,
        message: String,
        ingredientIDs: [String] = [],
        stageIDs: [String] = [],
        sourceEvidence: String? = nil,
        isResolved: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.message = message
        self.ingredientIDs = ingredientIDs
        self.stageIDs = stageIDs
        self.sourceEvidence = sourceEvidence
        self.isResolved = isResolved
    }
}

public enum RecipeSourceType: String, Codable, CaseIterable, Sendable {
    case url
    case text
    case images
    case manual
    case sample
}

public struct RecipeProvenance: Codable, Hashable, Sendable {
    public var sourceType: RecipeSourceType
    public var url: String?
    public var title: String?
    public var cleanedText: String?
    public var importedAt: String

    public init(
        sourceType: RecipeSourceType,
        url: String? = nil,
        title: String? = nil,
        cleanedText: String? = nil,
        importedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.sourceType = sourceType
        self.url = url
        self.title = title
        self.cleanedText = cleanedText
        self.importedAt = importedAt
    }
}

public enum RecipeCoding {
    public static let encoder = CanonicalRecipeEncoder()
    public static let decoder = JSONDecoder()
}

public struct CanonicalRecipeEncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        guard value is RecipeV1 else { return encoded }
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        normalizeRecipeNulls(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func normalizeRecipeNulls(_ recipe: inout [String: Any]) {
        recipe["summary"] = recipe["summary"] ?? NSNull()
        if var yield = recipe["yield"] as? [String: Any] {
            yield["label"] = yield["label"] ?? NSNull()
            recipe["yield"] = yield
        }
        if var ingredients = recipe["ingredients"] as? [[String: Any]] {
            for index in ingredients.indices {
                ingredients[index]["quantity"] = ingredients[index]["quantity"] ?? NSNull()
                ingredients[index]["notes"] = ingredients[index]["notes"] ?? NSNull()
                if var quantity = ingredients[index]["quantity"] as? [String: Any] {
                    normalizeQuantity(&quantity)
                    ingredients[index]["quantity"] = quantity
                }
            }
            recipe["ingredients"] = ingredients
        }
        if var stages = recipe["stages"] as? [[String: Any]] {
            for index in stages.indices {
                for key in ["completionCue", "workstreamID", "resultLabel", "duration", "heat", "temperature", "notes"] {
                    stages[index][key] = stages[index][key] ?? NSNull()
                }
                if var duration = stages[index]["duration"] as? [String: Any] {
                    duration["maximumSeconds"] = duration["maximumSeconds"] ?? NSNull()
                    stages[index]["duration"] = duration
                }
                if var uses = stages[index]["ingredientUses"] as? [[String: Any]] {
                    for useIndex in uses.indices {
                        uses[useIndex]["quantity"] = uses[useIndex]["quantity"] ?? NSNull()
                        uses[useIndex]["stateChange"] = uses[useIndex]["stateChange"] ?? NSNull()
                        if var quantity = uses[useIndex]["quantity"] as? [String: Any] {
                            normalizeQuantity(&quantity)
                            uses[useIndex]["quantity"] = quantity
                        }
                    }
                    stages[index]["ingredientUses"] = uses
                }
            }
            recipe["stages"] = stages
        }
        if var uncertainties = recipe["uncertainties"] as? [[String: Any]] {
            for index in uncertainties.indices {
                uncertainties[index]["sourceEvidence"] = uncertainties[index]["sourceEvidence"] ?? NSNull()
            }
            recipe["uncertainties"] = uncertainties
        }
        if var provenance = recipe["provenance"] as? [String: Any] {
            for key in ["url", "title", "cleanedText"] { provenance[key] = provenance[key] ?? NSNull() }
            recipe["provenance"] = provenance
        }
    }

    private func normalizeQuantity(_ quantity: inout [String: Any]) {
        for key in ["value", "lower", "upper", "text", "originalText"] {
            quantity[key] = quantity[key] ?? NSNull()
        }
    }
}
