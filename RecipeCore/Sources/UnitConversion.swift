import Foundation

public enum UnitSystemPreference: String, Codable, CaseIterable, Sendable {
    case source
    case metric
    case imperial
}

public enum UnitDimension: Sendable {
    case none
    case mass
    case volume
    case temperature
    case count
    case qualitative
}

public enum UnitConversionError: Error, Equatable, LocalizedError {
    case incompatibleUnits(UnitID, UnitID)
    case qualitativeQuantity

    public var errorDescription: String? {
        switch self {
        case let .incompatibleUnits(source, destination):
            "Cannot convert \(source.rawValue) to \(destination.rawValue)."
        case .qualitativeQuantity:
            "Qualitative quantities cannot be converted."
        }
    }
}

public enum CulinaryUnits {
    public static func dimension(of unit: UnitID) -> UnitDimension {
        switch unit {
        case .gram, .kilogram, .ounce, .pound:
            .mass
        case .milliliter, .liter, .teaspoon, .tablespoon, .cup, .fluidOunce, .pint, .shot:
            .volume
        case .celsius, .fahrenheit:
            .temperature
        case .count, .clove, .slice, .can, .package, .bunch, .sprig:
            .count
        case .none:
            .none
        case .pinch:
            .qualitative
        }
    }

    public static func converted(_ value: Decimal, from source: UnitID, to destination: UnitID) throws -> Decimal {
        guard source != destination else { return value }
        let sourceDimension = dimension(of: source)
        guard sourceDimension == dimension(of: destination) else {
            throw UnitConversionError.incompatibleUnits(source, destination)
        }

        switch sourceDimension {
        case .mass:
            return value * massFactorToGrams(source) / massFactorToGrams(destination)
        case .volume:
            return value * volumeFactorToMilliliters(source) / volumeFactorToMilliliters(destination)
        case .temperature:
            let celsius = source == .fahrenheit ? (value - 32) * 5 / 9 : value
            return destination == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        case .count, .none:
            throw UnitConversionError.incompatibleUnits(source, destination)
        case .qualitative:
            throw UnitConversionError.qualitativeQuantity
        }
    }

    private static func massFactorToGrams(_ unit: UnitID) -> Decimal {
        switch unit {
        case .gram: 1
        case .kilogram: 1_000
        case .ounce: Decimal(string: "28.349523125")!
        case .pound: Decimal(string: "453.59237")!
        default: 1
        }
    }

    private static func volumeFactorToMilliliters(_ unit: UnitID) -> Decimal {
        switch unit {
        case .milliliter: 1
        case .liter: 1_000
        case .teaspoon: Decimal(string: "4.92892159375")!
        case .tablespoon: Decimal(string: "14.78676478125")!
        case .cup: Decimal(string: "236.5882365")!
        case .fluidOunce: Decimal(string: "29.5735295625")!
        case .pint: Decimal(string: "473.176473")!
        case .shot: 30
        default: 1
        }
    }

    /// The unit an amount is shown in for `preference`.
    ///
    /// Teaspoons and tablespoons are never converted: metric recipes use the same spoon
    /// measures (1 tsp = 5 ml, 1 tbsp = 15 ml), and US recipes measure small amounts in them too.
    /// Cups, fluid ounces and pints become millilitres or litres in metric. They are not turned
    /// into grams, which would need the density of each ingredient.
    /// Thresholds compare the rounded amount, so an amount that rounds up to 1 kg or 2 cups uses the larger unit.
    public static func preferredUnit(for value: Decimal, unit: UnitID, preference: UnitSystemPreference) -> UnitID {
        guard preference != .source, !isSpoon(unit) else { return unit }
        switch dimension(of: unit) {
        case .mass:
            let grams = (try? converted(value, from: unit, to: .gram)) ?? value
            if preference == .metric {
                return roundedForDisplay(grams, unit: .gram) >= 1_000 ? .kilogram : .gram
            }
            let ounces = (try? converted(grams, from: .gram, to: .ounce)) ?? grams
            return roundedForDisplay(ounces, unit: .ounce) >= 16 ? .pound : .ounce
        case .volume:
            let milliliters = (try? converted(value, from: unit, to: .milliliter)) ?? value
            if preference == .metric {
                return roundedForDisplay(milliliters, unit: .milliliter) >= 1_000 ? .liter : .milliliter
            }
            let cups = (try? converted(milliliters, from: .milliliter, to: .cup)) ?? 0
            if roundedForDisplay(cups, unit: .cup) >= 2 { return .pint }
            if milliliters >= 118 { return .cup }
            if milliliters >= 15 { return .tablespoon }
            return .teaspoon
        case .temperature:
            return preference == .metric ? .celsius : .fahrenheit
        case .none, .count, .qualitative:
            return unit
        }
    }

    static func isSpoon(_ unit: UnitID) -> Bool {
        unit == .teaspoon || unit == .tablespoon
    }

    static func isMetric(_ unit: UnitID) -> Bool {
        switch unit {
        case .gram, .kilogram, .milliliter, .liter: true
        default: false
        }
    }

    /// Rounds an amount to something you can measure in `unit`. Amounts in other units are returned as they are.
    ///
    /// - Grams: whole grams from 10 g, because kitchen scales read to 1 g; kilograms to 10 g.
    /// - Millilitres: the coarsest of 1, 5, 10, 25 and 50 ml that stays within 5%, because jugs are read by eye:
    ///   1 ml below 50 ml, then 5, 10, 25 and 50 ml from 50, 100, 250 and 500 ml. A US cup (236.6 ml) is 240 ml.
    ///   Litres round to 50 ml.
    /// - Below 10 g or 10 ml: two significant figures, so small amounts such as raising agents stay accurate.
    /// - Spoons, cups, pints and fluid ounces: the nearest eighth or third, the sizes in spoon and cup sets.
    /// - Ounces and pounds: the nearest eighth.
    /// - Imperial amounts too small for the smallest fraction keep two significant figures.
    ///
    /// Every step either divides the next or lands on its boundary, so rounding again changes nothing.
    static func roundedForDisplay(_ value: Decimal, unit: UnitID) -> Decimal {
        guard value > 0 else { return value }
        switch unit {
        case .gram:
            return rounded(value, toMultipleOf: value < 10 ? significantStep(for: value) : 1)
        case .kilogram:
            return rounded(value, toMultipleOf: Decimal(string: "0.01")!)
        case .milliliter:
            let step: Decimal = switch value {
            case ..<10: significantStep(for: value)
            case ..<50: 1
            case ..<100: 5
            case ..<250: 10
            case ..<500: 25
            default: 50
            }
            return rounded(value, toMultipleOf: step)
        case .liter:
            return rounded(value, toMultipleOf: Decimal(string: "0.05")!)
        case .teaspoon, .tablespoon, .cup, .fluidOunce, .pint:
            return roundedToFraction(value, of: eighthsAndThirds)
        case .ounce, .pound:
            return roundedToFraction(value, of: eighths)
        default:
            return value
        }
    }

    private static let eighths: [Decimal] = (0...8).map { Decimal($0) / 8 }
    private static let eighthsAndThirds: [Decimal] = eighths + [Decimal(1) / 3, Decimal(2) / 3]

    /// The step that keeps two significant figures of an amount below 10.
    private static func significantStep(for value: Decimal) -> Decimal {
        var step = Decimal(string: "0.1")!
        while value < step * 10, step > Decimal(string: "0.0001")! {
            step /= 10
        }
        return step
    }

    private static func rounded(_ value: Decimal, toMultipleOf step: Decimal) -> Decimal {
        var quotient = value / step
        var whole = Decimal()
        NSDecimalRound(&whole, &quotient, 0, .plain)
        return whole * step
    }

    private static func roundedToFraction(_ value: Decimal, of fractions: [Decimal]) -> Decimal {
        var copy = value
        var whole = Decimal()
        NSDecimalRound(&whole, &copy, 0, .down)
        let remainder = value - whole
        let nearest = fractions.min { abs($0 - remainder) < abs($1 - remainder) }!
        let result = whole + nearest
        // Too small for the smallest fraction: keep two significant figures rather than show nothing.
        return result > 0 ? result : rounded(value, toMultipleOf: significantStep(for: value))
    }

    public static func symbol(for unit: UnitID, plural: Bool = false) -> String {
        switch unit {
        case .none: ""
        case .gram: "g"
        case .kilogram: "kg"
        case .ounce: "oz"
        case .pound: "lb"
        case .milliliter: "ml"
        case .liter: "l"
        case .teaspoon: "tsp"
        case .tablespoon: "tbsp"
        case .cup: plural ? "cups" : "cup"
        case .fluidOunce: "fl oz"
        case .pint: plural ? "pints" : "pint"
        case .celsius: "°C"
        case .fahrenheit: "°F"
        case .count: ""
        case .pinch: plural ? "pinches" : "pinch"
        case .clove: plural ? "cloves" : "clove"
        case .slice: plural ? "slices" : "slice"
        case .can: plural ? "cans" : "can"
        case .package: plural ? "packages" : "package"
        case .bunch: plural ? "bunches" : "bunch"
        case .sprig: plural ? "sprigs" : "sprig"
        case .shot: plural ? "shots" : "shot"
        }
    }
}

public extension CulinaryQuantity {
    func scaled(by factor: Decimal, enabled: Bool = true) -> CulinaryQuantity {
        guard enabled, factor != 1 else { return self }
        var copy = self
        switch kind {
        case .exact:
            copy.value = value.map { $0 * factor }
        case .range:
            copy.lower = lower.map { $0 * factor }
            copy.upper = upper.map { $0 * factor }
        case .text:
            break
        }
        return copy
    }

    /// The amount in the units `preference` uses, rounded to what can be measured in them.
    /// Source amounts are returned exactly as written.
    func converted(for preference: UnitSystemPreference) -> CulinaryQuantity {
        guard kind != .text, preference != .source else { return self }
        let representative = value ?? lower ?? upper ?? 0
        let preferred = CulinaryUnits.preferredUnit(for: representative, unit: unit, preference: preference)
        let roundsInPreference = switch preference {
        case .metric: CulinaryUnits.isMetric(preferred) || CulinaryUnits.isSpoon(preferred)
        case .imperial: CulinaryUnits.dimension(of: preferred) == .mass || CulinaryUnits.dimension(of: preferred) == .volume
        case .source: false
        }
        guard preferred != unit || roundsInPreference else { return self }

        let source = unit
        func convert(_ amount: Decimal) -> Decimal? {
            let converted = source == preferred ? amount : try? CulinaryUnits.converted(amount, from: source, to: preferred)
            return converted.map { roundsInPreference ? CulinaryUnits.roundedForDisplay($0, unit: preferred) : $0 }
        }
        var copy = self
        copy.value = value.flatMap(convert)
        copy.lower = lower.flatMap(convert)
        copy.upper = upper.flatMap(convert)
        copy.unit = preferred
        return copy
    }

    /// Grams, kilograms, millilitres and litres are written as decimals ("2.5 ml"), never as vulgar fractions:
    /// kilograms and litres to the gram or millilitre, and amounts under 1 g or 1 ml to three significant figures.
    /// Other units use fractions where they are close ("½ tsp"), and weights and volumes too small for any fraction
    /// use decimals.
    func displayString() -> String {
        switch kind {
        case .text:
            return text ?? originalText ?? "as needed"
        case .exact:
            return formatted(value ?? 0)
        case .range:
            let lowerValue = lower ?? 0
            let upperValue = upper ?? lowerValue
            let amount = "\(formattedAmount(lowerValue))–\(formattedAmount(upperValue))"
            let symbol = CulinaryUnits.symbol(for: unit, plural: upperValue > 1)
            return symbol.isEmpty ? amount : "\(amount) \(symbol)"
        }
    }

    private func formatted(_ value: Decimal) -> String {
        let amount = formattedAmount(value)
        let number = NSDecimalNumber(decimal: value).doubleValue
        let symbol = CulinaryUnits.symbol(for: unit, plural: number > 1.000_1)
        return symbol.isEmpty ? amount : "\(amount) \(symbol)"
    }

    private func formattedAmount(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value).doubleValue
        switch unit {
        case .kilogram, .liter:
            return number.formatted(.number.precision(.fractionLength(0...3)))
        case .gram, .milliliter:
            return Self.decimalAmount(number)
        default:
            break
        }
        let whole = floor(number + 0.000_001)
        let fraction = number - whole
        let candidates: [(Double, String)] = [
            (0, ""), (0.125, "⅛"), (1.0 / 6.0, "⅙"), (0.25, "¼"), (1.0 / 3.0, "⅓"),
            (0.375, "⅜"), (0.5, "½"), (0.625, "⅝"), (2.0 / 3.0, "⅔"), (0.75, "¾"),
            (5.0 / 6.0, "⅚"), (0.875, "⅞"), (1, "")
        ]
        let nearest = candidates.min { abs($0.0 - fraction) < abs($1.0 - fraction) }!
        let adjustedWhole = nearest.0 == 1 ? whole + 1 : whole
        let amount: String
        if abs(nearest.0 - fraction) < 0.025 {
            if adjustedWhole == 0 {
                // A weight or volume below the smallest fraction must not read as nothing. Counts still read "0",
                // which callers use to leave out amounts too small to show, such as a sliver of a vanilla pod.
                let measurable = [.mass, .volume].contains(CulinaryUnits.dimension(of: unit))
                amount = nearest.1.isEmpty ? (number > 0 && measurable ? Self.decimalAmount(number) : "0") : nearest.1
            } else {
                amount = "\(Int(adjustedWhole))\(nearest.1)"
            }
        } else {
            amount = number.formatted(.number.precision(.fractionLength(0...2)))
        }
        return amount
    }

    private static func decimalAmount(_ number: Double) -> String {
        abs(number) < 1
            ? number.formatted(.number.precision(.significantDigits(1...3)))
            : number.formatted(.number.precision(.fractionLength(0...2)))
    }
}

public extension Ingredient {
    func displayQuantity(servings: Decimal, originalServings: Decimal, units: UnitSystemPreference) -> String? {
        guard let quantity else { return nil }
        let factor = originalServings > 0 ? servings / originalServings : 1
        return quantity.scaled(by: factor, enabled: scalable).converted(for: units).displayString()
    }
}

public extension CookingTemperature {
    func converted(for preference: UnitSystemPreference) -> CookingTemperature {
        guard preference != .source else { return self }
        let desired: TemperatureUnit = preference == .metric ? .celsius : .fahrenheit
        guard desired != unit else { return self }
        let sourceID: UnitID = unit == .celsius ? .celsius : .fahrenheit
        let destinationID: UnitID = desired == .celsius ? .celsius : .fahrenheit
        let converted = (try? CulinaryUnits.converted(value, from: sourceID, to: destinationID)) ?? value
        return .init(value: converted, unit: desired)
    }

    func displayString() -> String {
        let rounded = NSDecimalNumber(decimal: value).doubleValue.formatted(.number.precision(.fractionLength(0...1)))
        return "\(rounded)\(unit == .celsius ? "°C" : "°F")"
    }
}
