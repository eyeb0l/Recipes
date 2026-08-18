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

    public static func preferredUnit(for value: Decimal, unit: UnitID, preference: UnitSystemPreference) -> UnitID {
        guard preference != .source else { return unit }
        switch dimension(of: unit) {
        case .mass:
            let grams = (try? converted(value, from: unit, to: .gram)) ?? value
            if preference == .metric {
                return grams >= 1_000 ? .kilogram : .gram
            }
            let ounces = (try? converted(grams, from: .gram, to: .ounce)) ?? grams
            return ounces >= 16 ? .pound : .ounce
        case .volume:
            let milliliters = (try? converted(value, from: unit, to: .milliliter)) ?? value
            if preference == .metric {
                return milliliters >= 1_000 ? .liter : .milliliter
            }
            if milliliters >= 473 { return .pint }
            if milliliters >= 118 { return .cup }
            if milliliters >= 15 { return .tablespoon }
            return .teaspoon
        case .temperature:
            return preference == .metric ? .celsius : .fahrenheit
        case .none, .count, .qualitative:
            return unit
        }
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

    func converted(for preference: UnitSystemPreference) -> CulinaryQuantity {
        guard kind != .text else { return self }
        let representative = value ?? lower ?? upper ?? 0
        let preferred = CulinaryUnits.preferredUnit(for: representative, unit: unit, preference: preference)
        guard preferred != unit else { return self }

        var copy = self
        copy.value = value.flatMap { try? CulinaryUnits.converted($0, from: unit, to: preferred) }
        copy.lower = lower.flatMap { try? CulinaryUnits.converted($0, from: unit, to: preferred) }
        copy.upper = upper.flatMap { try? CulinaryUnits.converted($0, from: unit, to: preferred) }
        copy.unit = preferred
        return copy
    }

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
                amount = nearest.1.isEmpty ? "0" : nearest.1
            } else {
                amount = "\(Int(adjustedWhole))\(nearest.1)"
            }
        } else {
            amount = number.formatted(.number.precision(.fractionLength(0...2)))
        }
        return amount
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
