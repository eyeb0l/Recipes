import Foundation

/// One thing to buy, with the amount the chosen servings need.
public struct ShoppingListItem: Hashable, Identifiable, Sendable {
    /// The first ingredient this item came from.
    public var id: String
    /// Every ingredient folded into this item, when a recipe lists the same thing more than once.
    public var ingredientIDs: [String]
    public var name: String
    public var quantity: String?

    public init(id: String, ingredientIDs: [String], name: String, quantity: String?) {
        self.id = id
        self.ingredientIDs = ingredientIDs
        self.name = name
        self.quantity = quantity
    }
}

/// A reminder already in the chosen list.
public struct ExistingShoppingReminder: Hashable, Sendable {
    public var id: String
    public var title: String
    public var notes: String?

    public init(id: String, title: String, notes: String?) {
        self.id = id
        self.title = title
        self.notes = notes
    }
}

/// The changes that add a recipe's items to a reminders list without duplicating what's there.
public struct ShoppingReminderPlan: Equatable, Sendable {
    public struct NewReminder: Equatable, Sendable {
        public var title: String
        public var notes: String
    }

    public struct NotesUpdate: Equatable, Sendable {
        public var reminderID: String
        public var notes: String
    }

    public var newReminders: [NewReminder] = []
    public var notesUpdates: [NotesUpdate] = []
    /// Items the list already had for this recipe at this amount.
    public var alreadyListedCount = 0

    public var isEmpty: Bool { newReminders.isEmpty && notesUpdates.isEmpty }
}

public enum ShoppingList {
    /// The recipe's ingredients as things to buy, scaled to `servings` and expressed in `units`.
    ///
    /// Ingredients with the same name are combined, and their amounts added up when the units allow.
    public static func items(for recipe: RecipeV1, servings: Decimal, units: UnitSystemPreference) -> [ShoppingListItem] {
        let base = recipe.recipeYield.resolvedServings
        let factor = base > 0 ? servings / base : 1
        var order: [String] = []
        var groups: [String: [Ingredient]] = [:]
        for ingredient in recipe.sortedIngredients {
            let key = matchingKey(for: ingredient.name)
            guard !key.isEmpty else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(ingredient)
        }
        return order.compactMap { key in
            guard let ingredients = groups[key], let first = ingredients.first else { return nil }
            let quantities = ingredients.compactMap { ingredient in
                ingredient.quantity?.scaled(by: factor, enabled: ingredient.scalable)
            }
            return ShoppingListItem(
                id: first.id,
                ingredientIDs: ingredients.map(\.id),
                name: displayName(first.name),
                quantity: combinedQuantity(quantities, units: units)
            )
        }
    }

    /// The reminder note for an item: its amount and the recipe it's for, such as "200 g · Brownies".
    public static func reminderNote(for item: ShoppingListItem, recipeTitle: String) -> String {
        [item.quantity, recipeTitle].compactMap { value in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        .joined(separator: " · ")
    }

    /// Works out which reminders to add, and which existing reminders to annotate, for `items`.
    ///
    /// An incomplete reminder with the same name is reused rather than duplicated: the recipe's amount
    /// goes on its own line in the reminder's notes. Adding the same recipe again at the same amount
    /// changes nothing; at a different amount, it replaces that recipe's line.
    public static func plan(
        adding items: [ShoppingListItem],
        recipeTitle: String,
        to existing: [ExistingShoppingReminder]
    ) -> ShoppingReminderPlan {
        var plan = ShoppingReminderPlan()
        var existingByKey: [String: ExistingShoppingReminder] = [:]
        for reminder in existing {
            let key = matchingKey(for: reminder.title)
            if !key.isEmpty, existingByKey[key] == nil { existingByKey[key] = reminder }
        }
        var updatedNotes: [String: String] = [:]
        var updateOrder: [String] = []

        for item in items {
            let note = reminderNote(for: item, recipeTitle: recipeTitle)
            guard let reminder = existingByKey[matchingKey(for: item.name)] else {
                plan.newReminders.append(.init(title: item.name, notes: note))
                continue
            }
            var lines = (updatedNotes[reminder.id] ?? reminder.notes ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.contains(note) {
                plan.alreadyListedCount += 1
                continue
            }
            // One line per recipe: adding it again at a different amount replaces its earlier line.
            if let index = lines.firstIndex(where: { $0 == recipeTitle || $0.hasSuffix(" · \(recipeTitle)") }) {
                lines[index] = note
            } else {
                lines.append(note)
            }
            if updatedNotes[reminder.id] == nil { updateOrder.append(reminder.id) }
            updatedNotes[reminder.id] = lines.joined(separator: "\n")
        }
        plan.notesUpdates = updateOrder.map { .init(reminderID: $0, notes: updatedNotes[$0] ?? "") }
        return plan
    }

    // MARK: Helpers

    /// A key that treats "Large eggs", "large egg" and "large  eggs" as the same thing to buy.
    static func matchingKey(for name: String) -> String {
        IngredientName.words(in: name)
            .map { word in
                guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
                return String(word.dropLast())
            }
            .joined(separator: " ")
    }

    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// Adds up amounts that share a dimension; otherwise lists them, as in "2 tbsp + a handful".
    static func combinedQuantity(_ quantities: [CulinaryQuantity], units: UnitSystemPreference) -> String? {
        guard let first = quantities.first else { return nil }
        if quantities.count > 1, let total = sum(quantities, in: first.unit) {
            return total.converted(for: units).displayString()
        }
        let parts = quantities.map { $0.converted(for: units).displayString() }
        return parts.joined(separator: " + ")
    }

    private static func sum(_ quantities: [CulinaryQuantity], in unit: UnitID) -> CulinaryQuantity? {
        var lower: Decimal = 0
        var upper: Decimal = 0
        var isRange = false
        for quantity in quantities {
            let values: (Decimal, Decimal)
            switch quantity.kind {
            case .exact:
                guard let value = quantity.value else { return nil }
                values = (value, value)
            case .range:
                guard let low = quantity.lower, let high = quantity.upper else { return nil }
                values = (low, high)
                isRange = true
            case .text:
                return nil
            }
            let converted: (Decimal, Decimal)
            if quantity.unit == unit {
                converted = values
            } else {
                let dimension = CulinaryUnits.dimension(of: unit)
                guard dimension == .mass || dimension == .volume,
                      let low = try? CulinaryUnits.converted(values.0, from: quantity.unit, to: unit),
                      let high = try? CulinaryUnits.converted(values.1, from: quantity.unit, to: unit)
                else { return nil }
                converted = (low, high)
            }
            lower += converted.0
            upper += converted.1
        }
        return isRange ? .range(lower, upper, unit: unit) : .exact(lower, unit: unit)
    }
}
