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
        /// The notes this update was worked out from. A store applies it only if they're unchanged.
        public var previousNotes: String?
        /// The reminder's title when the update was worked out. A store applies it only if it's unchanged.
        public var previousTitle: String
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
            // Trimmed, since notes lines are compared trimmed when the recipe is added again.
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
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
        var remindersByID: [String: ExistingShoppingReminder] = [:]

        for item in items {
            let note = reminderNote(for: item, recipeTitle: recipeTitle)
            guard let reminder = existingByKey[matchingKey(for: item.name)] else {
                plan.newReminders.append(.init(title: item.name, notes: note))
                continue
            }
            let current = updatedNotes[reminder.id] ?? reminder.notes ?? ""
            // Keep the notes exactly as they are, including anything the person wrote themselves and
            // whichever line breaks they used.
            var lines = notesLines(current)
            let trimmed = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }
            if trimmed.contains(note) {
                plan.alreadyListedCount += 1
                continue
            }
            let updated: String
            // One line per recipe: adding it again at a different amount replaces the line it wrote before,
            // but only when exactly one line could be that line. Otherwise the new line is added below.
            let earlier = trimmed.indices.filter { isEarlierLine(trimmed[$0], for: note, recipeTitle: recipeTitle) }
            if earlier.count == 1, let index = earlier.first {
                lines[index].text = note
                updated = lines.map { $0.text + $0.lineBreak }.joined()
            } else if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated = note
            } else {
                updated = current + (current.last?.isNewline == true ? "" : "\n") + note
            }
            if updatedNotes[reminder.id] == nil {
                updateOrder.append(reminder.id)
                remindersByID[reminder.id] = reminder
            }
            updatedNotes[reminder.id] = updated
        }
        plan.notesUpdates = updateOrder.map {
            .init(
                reminderID: $0,
                notes: updatedNotes[$0] ?? "",
                previousNotes: remindersByID[$0]?.notes,
                previousTitle: remindersByID[$0]?.title ?? ""
            )
        }
        return plan
    }

    /// Notes split into lines, each with the line break that ended it ("" for the last line).
    static func notesLines(_ notes: String) -> [(text: String, lineBreak: String)] {
        var lines: [(text: String, lineBreak: String)] = []
        var text = ""
        for character in notes {
            if character.isNewline {
                lines.append((text, String(character)))
                text = ""
            } else {
                text.append(character)
            }
        }
        lines.append((text, ""))
        return lines
    }

    /// Whether `line` could be the line this app wrote for the recipe before, at other servings: it's for
    /// exactly the same recipe title, and its amount differs from the new one only in its numbers. So
    /// "1 clove · Stew" is, but "2 dozen in the cupboard · Stew" and "1 clove · Stew 2" aren't.
    static func isEarlierLine(_ line: String, for note: String, recipeTitle: String) -> Bool {
        let suffix = " · \(recipeTitle.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard line.hasSuffix(suffix), note.hasSuffix(suffix) else { return false }
        let earlier = String(line.dropLast(suffix.count))
        let amount = String(note.dropLast(suffix.count))
        return !earlier.isEmpty && amountPattern(earlier) == amountPattern(amount)
    }

    /// An amount with its numbers blanked out, plurals ignored and units reduced to what they measure, so
    /// "1 clove" and "2 cloves" match, and so do "600 g", "1.2 kg" and "1 lb".
    static func amountPattern(_ amount: String) -> String {
        var pattern = ""
        var word = ""
        var inNumber = false
        func endWord() {
            let stem = stem(word)
            pattern += measureWords[stem] ?? stem
            word = ""
        }
        var amount = amount
        for (symbol, joined) in multiWordSymbols {
            amount = amount.replacingOccurrences(of: symbol, with: joined)
        }
        let characters = Array(amount)
        for (index, character) in characters.enumerated() {
            // Inside a number, decimal and grouping separators belong to it, including the spaces some
            // locales group digits with, as in "1 200,5".
            let continuesNumber = inNumber
                && (character.isWhitespace || ".,/'’٫٬".contains(character))
                && characters.indices.contains(index + 1) && characters[index + 1].isNumber
            if character.isNumber || continuesNumber {
                endWord()
                // A character no one types, so a literal "#" in a note isn't mistaken for a number.
                if !inNumber { pattern += "\u{E000}" }
                inNumber = true
            } else if character.isLetter {
                inNumber = false
                word.append(character)
            } else {
                endWord()
                inNumber = false
                pattern.append(character)
            }
        }
        endWord()
        return pattern
    }

    /// A word lower-cased with plurals ignored: "clove" and "cloves", "pinch" and "pinches".
    private static func stem(_ word: String) -> String {
        var stem = word.lowercased()
        if stem.hasSuffix("s") { stem.removeLast() }
        if stem.hasSuffix("e") { stem.removeLast() }
        return stem
    }

    /// Unit symbols written as more than one word, such as "fl oz", and the single word used in their place.
    private static let multiWordSymbols: [(String, String)] = UnitID.allCases.flatMap { unit in
        [false, true].map { CulinaryUnits.symbol(for: unit, plural: $0) }
            .filter { $0.contains(" ") }
            .map { ($0, $0.replacingOccurrences(of: " ", with: "")) }
    }

    /// Weight and volume unit symbols, keyed by stem, and a stand-in for what they measure. Scaling or
    /// switching unit system can change "g" to "kg" or "oz", but never weight to volume.
    private static let measureWords: [String: String] = {
        var words: [String: String] = [:]
        for unit in UnitID.allCases {
            let measure: String
            switch CulinaryUnits.dimension(of: unit) {
            case .mass: measure = "\u{E001}"
            case .volume: measure = "\u{E002}"
            default: continue
            }
            for plural in [false, true] {
                words[stem(CulinaryUnits.symbol(for: unit, plural: plural).replacingOccurrences(of: " ", with: ""))] = measure
            }
        }
        return words
    }()

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
