import Foundation

/// A substitute for an ingredient, with its amounts worked out for the servings being cooked.
public struct IngredientSubstitute: Hashable, Identifiable, Sendable {
    public struct Component: Hashable, Sendable {
        public var name: String
        /// The amount to use, or `nil` when it can't be worked out from the recipe's amount.
        public var quantity: CulinaryQuantity?

        public init(name: String, quantity: CulinaryQuantity?) {
            self.name = name
            self.quantity = quantity
        }
    }

    public var id: String
    public var title: String
    public var components: [Component]
    /// How to prepare the substitute and how it changes the result.
    public var note: String

    public init(id: String, title: String, components: [Component], note: String) {
        self.id = id
        self.title = title
        self.components = components
        self.note = note
    }
}

/// A built-in, offline catalogue of common kitchen substitutions.
///
/// Substitutes are matched on the ingredient's name and scaled from its amount, so they follow the
/// servings and units the cook has chosen. The catalogue is deliberately conservative: it only covers
/// swaps that work in most recipes, and each one says how it changes the result.
public enum IngredientSubstitutions {
    /// Whether the catalogue has any substitute for an ingredient with this name.
    public static func hasSubstitutes(for ingredientName: String) -> Bool {
        rule(for: ingredientName) != nil
    }

    /// Substitutes for an ingredient, with amounts scaled to `servings` and expressed in `units`.
    public static func substitutes(
        for ingredient: Ingredient,
        servings: Decimal,
        originalServings: Decimal,
        units: UnitSystemPreference
    ) -> [IngredientSubstitute] {
        guard let rule = rule(for: ingredient.name) else { return [] }
        let factor = originalServings > 0 ? servings / originalServings : 1
        let base = ingredient.quantity?.scaled(by: factor, enabled: ingredient.scalable)
        return rule.options.map { option in
            IngredientSubstitute(
                id: "\(rule.id).\(option.id)",
                title: option.title,
                components: option.components.map { component in
                    .init(
                        name: component.name,
                        quantity: base.flatMap { component.amount.quantity(replacing: $0) }?.converted(for: units)
                    )
                },
                note: option.note
            )
        }
    }

    // MARK: Matching

    static func rule(for ingredientName: String) -> SubstitutionRule? {
        let words = IngredientName.words(in: ingredientName)
        guard !words.isEmpty else { return nil }
        var best: (rule: SubstitutionRule, specificity: Int)?
        for rule in catalogue {
            guard !rule.excludedWords.contains(where: { IngredientName.contains(words, phrase: [$0]) }) else { continue }
            let specificity = rule.phrases
                .map(IngredientName.words(in:))
                .filter { IngredientName.contains(words, phrase: $0) }
                .map(\.count)
                .max()
            if let specificity, specificity > (best?.specificity ?? 0) {
                best = (rule, specificity)
            }
        }
        return best?.rule
    }
}

/// Name normalisation shared by substitution matching and shopping lists.
enum IngredientName {
    /// Lower-cased, accent-folded words, with punctuation treated as spaces.
    static func words(in name: String) -> [String] {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Whether `phrase` appears as consecutive words in `words`, allowing a plural "s" or "es".
    static func contains(_ words: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        for start in 0...(words.count - phrase.count) {
            let matches = phrase.indices.allSatisfy { offset in
                let word = words[start + offset]
                let target = phrase[offset]
                return word == target || word == target + "s" || word == target + "es"
            }
            if matches { return true }
        }
        return false
    }
}

// MARK: - Catalogue model

struct SubstitutionRule: Sendable {
    let id: String
    /// Names this rule applies to. The most specific (longest) matching phrase wins across rules.
    let phrases: [String]
    /// Words that mean a name is a different ingredient, such as "peanut" in "peanut butter".
    let excludedWords: [String]
    let options: [SubstitutionOption]

    init(_ id: String, phrases: [String], excluding excludedWords: [String] = [], options: [SubstitutionOption]) {
        self.id = id
        self.phrases = phrases
        self.excludedWords = excludedWords
        self.options = options
    }
}

struct SubstitutionOption: Sendable {
    let id: String
    let title: String
    let components: [SubstitutionComponent]
    let note: String

    init(_ id: String, _ title: String, _ components: [SubstitutionComponent], note: String) {
        self.id = id
        self.title = title
        self.components = components
        self.note = note
    }
}

struct SubstitutionComponent: Sendable {
    let name: String
    let amount: SubstituteAmount

    static func component(_ name: String, _ amount: SubstituteAmount) -> Self {
        .init(name: name, amount: amount)
    }
}

/// How much of a substitute component replaces the original ingredient.
enum SubstituteAmount: Sendable {
    /// A share of the original amount, in the original's unit. Each dimension can use its own ratio;
    /// `nil` means the amount can't be worked out for that dimension (say, a sprig of a dried herb).
    case proportion(mass: Decimal?, volume: Decimal?, count: Decimal?)
    /// A fixed amount for every `reference` of the original, for swaps that change units, such as
    /// one tablespoon of ground flaxseed per egg. References are tried in order.
    case per(Decimal, UnitID, references: [(Decimal, UnitID)])

    /// The same ratio whatever the original is measured in.
    static func same(_ ratio: Decimal = 1) -> Self {
        .proportion(mass: ratio, volume: ratio, count: ratio)
    }

    /// A ratio for weighed and measured amounts that has no sensible meaning for counted ones.
    static func measured(_ ratio: Decimal) -> Self {
        .proportion(mass: ratio, volume: ratio, count: nil)
    }

    func quantity(replacing original: CulinaryQuantity) -> CulinaryQuantity? {
        guard original.kind != .text else { return nil }
        switch self {
        case let .proportion(mass, volume, count):
            let ratio: Decimal? = switch CulinaryUnits.dimension(of: original.unit) {
            case .mass: mass
            case .volume: volume
            case .count, .none, .qualitative: count
            case .temperature: nil
            }
            guard let ratio else { return nil }
            var result = original.scaled(by: ratio)
            result.originalText = nil
            return result
        case let .per(amount, unit, references):
            for (referenceAmount, referenceUnit) in references {
                guard let multiplier = Self.multiplier(of: original, per: referenceAmount, referenceUnit) else { continue }
                switch original.kind {
                case .exact:
                    guard let value = original.value else { return nil }
                    return .exact(amount * value * multiplier, unit: unit)
                case .range:
                    guard let lower = original.lower, let upper = original.upper else { return nil }
                    return .range(amount * lower * multiplier, amount * upper * multiplier, unit: unit)
                case .text:
                    return nil
                }
            }
            return nil
        }
    }

    /// How many references one unit of the original amounts to, if the units are compatible.
    private static func multiplier(of original: CulinaryQuantity, per reference: Decimal, _ referenceUnit: UnitID) -> Decimal? {
        guard reference > 0 else { return nil }
        let unit = original.unit
        let countLike: Set<UnitID> = [.none, .count]
        if unit == referenceUnit || (countLike.contains(unit) && countLike.contains(referenceUnit)) {
            return 1 / reference
        }
        let dimension = CulinaryUnits.dimension(of: unit)
        guard dimension == .mass || dimension == .volume, dimension == CulinaryUnits.dimension(of: referenceUnit),
              let oneUnit = try? CulinaryUnits.converted(1, from: unit, to: referenceUnit)
        else { return nil }
        return oneUnit / reference
    }
}

// MARK: - Catalogue

extension IngredientSubstitutions {
    private static let sixteenth = Decimal(1) / 16
    private static let third = Decimal(1) / 3

    static let catalogue: [SubstitutionRule] = [
        SubstitutionRule(
            "buttermilk",
            phrases: ["buttermilk"],
            options: [
                .init("milk-lemon", "Milk and lemon juice", [
                    .component("milk", .same(1 - sixteenth)),
                    .component("lemon juice", .same(sixteenth))
                ], note: "Stir the lemon juice into the milk and leave it for 5–10 minutes, until it thickens slightly."),
                .init("yoghurt-milk", "Yoghurt and milk", [
                    .component("plain yoghurt", .same(0.75)),
                    .component("milk", .same(0.25))
                ], note: "Whisk together until smooth.")
            ]
        ),
        SubstitutionRule(
            "unsalted-butter",
            phrases: ["unsalted butter"],
            options: [
                .init("salted", "Salted butter", [.component("salted butter", .same())],
                      note: "Leave out about ¼ teaspoon of the recipe's salt for every 115 g (½ cup) of butter."),
                .init("oil", "Neutral oil", [.component("neutral oil", .same(0.8))],
                      note: "Only where the butter is melted, as in brownies, muffins and quick breads. Not for creaming, pastry or shortbread.")
            ]
        ),
        SubstitutionRule(
            "butter",
            phrases: ["butter"],
            excluding: ["peanut", "nut", "almond", "cashew", "apple", "cocoa", "shea", "bean", "lettuce", "icing"],
            options: [
                .init("unsalted", "Unsalted butter", [.component("unsalted butter", .same())],
                      note: "Add a pinch of salt if the dish tastes flat."),
                .init("oil", "Neutral oil", [.component("neutral oil", .same(0.8))],
                      note: "Only where the butter is melted, as in brownies, muffins and quick breads. Not for creaming, pastry or shortbread.")
            ]
        ),
        SubstitutionRule(
            "egg",
            phrases: ["egg"],
            excluding: ["yolk", "white", "wash", "noodle", "glaze", "replacer"],
            options: [
                .init("flax", "Flaxseed egg", [
                    .component("ground flaxseed", .per(1, .tablespoon, references: [(1, .count), (50, .gram)])),
                    .component("water", .per(3, .tablespoon, references: [(1, .count), (50, .gram)]))
                ], note: "Mix and leave for 10 minutes to thicken. Binds brownies, cookies and muffins, but can't replace whisked eggs in sponges or meringues."),
                .init("aquafaba", "Aquafaba", [
                    .component("aquafaba", .per(3, .tablespoon, references: [(1, .count), (50, .gram)]))
                ], note: "The liquid from a tin of chickpeas. Whisk it lightly before adding.")
            ]
        ),
        SubstitutionRule(
            "self-raising-flour",
            phrases: ["self raising flour", "self rising flour"],
            options: [
                .init("plain-baking-powder", "Plain flour and baking powder", [
                    .component("plain flour", .same()),
                    .component("baking powder", .per(2, .teaspoon, references: [(150, .gram), (1.25, .cup)]))
                ], note: "Sift them together twice so the baking powder is evenly spread.")
            ]
        ),
        SubstitutionRule(
            "plain-flour",
            phrases: ["plain flour", "all purpose flour"],
            options: [
                .init("gluten-free", "Gluten-free plain flour", [.component("gluten-free plain flour blend", .same())],
                      note: "Choose a blend that contains xanthan gum. Batters may need a splash more liquid.")
            ]
        ),
        SubstitutionRule(
            "baking-powder",
            phrases: ["baking powder"],
            options: [
                .init("soda-tartar", "Bicarbonate of soda and cream of tartar", [
                    .component("bicarbonate of soda", .measured(0.25)),
                    .component("cream of tartar", .measured(0.5))
                ], note: "Mix just before using; it starts to react as soon as it gets wet.")
            ]
        ),
        SubstitutionRule(
            "bicarbonate-of-soda",
            phrases: ["bicarbonate of soda", "baking soda", "bicarb", "bicarb soda", "sodium bicarbonate"],
            options: [
                .init("baking-powder", "Baking powder", [.component("baking powder", .measured(3))],
                      note: "Baking powder is weaker, so use three times as much. Expect a slightly paler, more cake-like result.")
            ]
        ),
        SubstitutionRule(
            "brown-sugar",
            phrases: ["brown sugar", "muscovado", "muscovado sugar"],
            options: [
                .init("sugar-treacle", "Sugar and treacle", [
                    .component("granulated sugar", .measured(1)),
                    .component("black treacle or molasses", .measured(sixteenth))
                ], note: "Rub the treacle into the sugar until it's evenly coloured. Double the treacle for dark brown sugar."),
                .init("white-sugar", "White sugar", [.component("granulated sugar", .same())],
                      note: "Bakes a little crisper and paler, with less caramel flavour.")
            ]
        ),
        SubstitutionRule(
            "caster-sugar",
            phrases: ["caster sugar", "castor sugar", "superfine sugar"],
            options: [
                .init("granulated", "Granulated sugar", [.component("granulated sugar", .same())],
                      note: "Blitz it briefly in a food processor so it dissolves as quickly.")
            ]
        ),
        SubstitutionRule(
            "icing-sugar",
            phrases: ["icing sugar", "powdered sugar", "confectioners sugar"],
            options: [
                .init("blended", "Blended granulated sugar", [.component("granulated sugar", .same())],
                      note: "Blitz in a clean, dry blender until very fine. Good for icing and dusting, not for meringues.")
            ]
        ),
        SubstitutionRule(
            "double-cream",
            phrases: ["double cream", "heavy cream", "whipping cream", "heavy whipping cream"],
            options: [
                .init("milk-butter", "Milk and melted butter", [
                    .component("whole milk", .measured(0.75)),
                    .component("unsalted butter, melted", .measured(0.25))
                ], note: "For sauces, soups and baking only; it won't whip.")
            ]
        ),
        SubstitutionRule(
            "sour-cream",
            phrases: ["sour cream", "soured cream"],
            options: [
                .init("greek-yoghurt", "Greek yoghurt", [.component("Greek yoghurt", .same())],
                      note: "Tangier and a little thinner. Stir it in off the heat so it doesn't split."),
                .init("creme-fraiche", "Crème fraîche", [.component("crème fraîche", .same())],
                      note: "Richer and milder, and safe to simmer.")
            ]
        ),
        SubstitutionRule(
            "creme-fraiche",
            phrases: ["creme fraiche"],
            options: [
                .init("sour-cream", "Soured cream", [.component("soured cream", .same())],
                      note: "Sharper, and may split if it boils.")
            ]
        ),
        SubstitutionRule(
            "greek-yoghurt",
            phrases: ["greek yoghurt", "greek yogurt", "greek style yoghurt", "greek style yogurt"],
            options: [
                .init("sour-cream", "Soured cream", [.component("soured cream", .same())],
                      note: "Richer and slightly less tangy.")
            ]
        ),
        SubstitutionRule(
            "milk",
            phrases: ["milk", "whole milk", "semi skimmed milk", "skimmed milk"],
            excluding: ["coconut", "condensed", "evaporated", "almond", "oat", "soy", "soya", "rice", "powder", "powdered", "chocolate", "dried"],
            options: [
                .init("plant", "Unsweetened soy or oat milk", [.component("unsweetened soy or oat milk", .same())],
                      note: "Soy behaves most like dairy milk in baking. Avoid sweetened or flavoured versions."),
                .init("evaporated", "Evaporated milk and water", [
                    .component("evaporated milk", .measured(0.5)),
                    .component("water", .measured(0.5))
                ], note: "Slightly richer and sweeter.")
            ]
        ),
        SubstitutionRule(
            "lemon-juice",
            phrases: ["lemon juice"],
            options: [
                .init("lime", "Lime juice", [.component("lime juice", .same())], note: "A little more floral."),
                .init("vinegar", "White wine vinegar", [.component("white wine vinegar", .measured(0.5))],
                      note: "Sharper, so use half as much. Best in dressings, marinades and buttermilk swaps, not where lemon is the main flavour.")
            ]
        ),
        SubstitutionRule(
            "lime-juice",
            phrases: ["lime juice"],
            options: [.init("lemon", "Lemon juice", [.component("lemon juice", .same())], note: "Less floral, but works almost everywhere.")]
        ),
        SubstitutionRule(
            "garlic",
            phrases: ["garlic", "garlic clove"],
            excluding: ["powder", "granule", "granulated", "paste", "oil", "salt", "bread", "puree", "black", "wild", "butter"],
            options: [
                .init("granules", "Garlic granules", [
                    .component("garlic granules", .per(0.125, .teaspoon, references: [(1, .clove), (1, .count)]))
                ], note: "Add them with the liquid rather than frying them, as they scorch easily."),
                .init("paste", "Garlic paste", [
                    .component("garlic paste", .per(1, .teaspoon, references: [(1, .clove), (1, .count)]))
                ], note: "Fry it briefly; it catches faster than chopped garlic.")
            ]
        ),
        SubstitutionRule(
            "shallot",
            phrases: ["shallot", "banana shallot"],
            options: [
                .init("onion", "Onion", [.component("small onion", .proportion(mass: 1, volume: 1, count: third))],
                      note: "A small red or white onion replaces about three shallots. Chop it finely and cook it a little longer.")
            ]
        ),
        SubstitutionRule(
            "fresh-herbs",
            phrases: ["thyme", "oregano", "rosemary", "sage", "tarragon", "dill", "parsley", "basil", "marjoram"],
            excluding: ["dried", "ground", "pickle", "pesto", "oil", "seed", "salt", "paste"],
            options: [
                .init("dried", "Dried herbs", [.component("dried herbs of the same kind", .measured(third))],
                      note: "Dried herbs are stronger, so use a third as much and add them early. About 1 teaspoon dried replaces a tablespoon of chopped fresh herbs, or a few sprigs. Dried basil and parsley taste quite different from fresh.")
            ]
        ),
        SubstitutionRule(
            "vanilla",
            phrases: ["vanilla extract", "vanilla essence"],
            options: [
                .init("paste", "Vanilla bean paste", [.component("vanilla bean paste", .same())], note: "Adds visible vanilla seeds."),
                .init("pod", "Vanilla pod", [.component("vanilla pod, seeds scraped", .per(1, .count, references: [(1, .tablespoon)]))],
                      note: "Scrape out the seeds and add them with the wet ingredients.")
            ]
        ),
        SubstitutionRule(
            "espresso",
            phrases: ["espresso", "strong coffee", "brewed coffee", "coffee"],
            excluding: ["powder", "instant", "bean", "ground", "granule", "liqueur", "extract"],
            options: [
                .init("instant-espresso", "Instant espresso powder", [
                    .component("instant espresso powder", .per(1, .teaspoon, references: [(60, .milliliter)])),
                    .component("hot water", .measured(1))
                ], note: "Dissolve the powder in the hot water."),
                .init("instant-coffee", "Instant coffee", [
                    .component("instant coffee", .per(2, .teaspoon, references: [(60, .milliliter)])),
                    .component("hot water", .measured(1))
                ], note: "Dissolve the coffee in the hot water. A little milder than espresso.")
            ]
        ),
        SubstitutionRule(
            "dark-chocolate",
            phrases: ["dark chocolate", "plain chocolate", "bittersweet chocolate", "semisweet chocolate", "semi sweet chocolate"],
            excluding: ["chip", "chunk", "shaving", "grated", "curl"],
            options: [
                .init("cocoa", "Cocoa, sugar and butter", [
                    .component("cocoa powder", .per(20, .gram, references: [(100, .gram)])),
                    .component("caster sugar", .per(50, .gram, references: [(100, .gram)])),
                    .component("unsalted butter", .per(35, .gram, references: [(100, .gram)]))
                ], note: "Closest to semisweet chocolate. Melt the butter and stir in the cocoa and sugar. For melting into batters and sauces, not for chunks or decoration.")
            ]
        ),
        SubstitutionRule(
            "unsweetened-chocolate",
            phrases: ["unsweetened chocolate", "baking chocolate", "unsweetened baking chocolate"],
            options: [
                .init("cocoa", "Cocoa and butter", [
                    .component("cocoa powder", .per(55, .gram, references: [(100, .gram)])),
                    .component("unsalted butter", .per(50, .gram, references: [(100, .gram)]))
                ], note: "Melt the butter and stir in the cocoa. For melting into batters and sauces.")
            ]
        ),
        SubstitutionRule(
            "cornflour",
            phrases: ["cornflour", "cornstarch", "corn starch"],
            options: [
                .init("plain-flour", "Plain flour", [.component("plain flour", .measured(2))],
                      note: "For thickening only. Cook it for a couple of minutes longer to lose the raw taste; the sauce will be less glossy."),
                .init("arrowroot", "Arrowroot", [.component("arrowroot", .same())],
                      note: "Add it near the end and don't let it boil hard. Not for dairy sauces, where it can turn slimy.")
            ]
        ),
        SubstitutionRule(
            "honey",
            phrases: ["honey", "runny honey"],
            excluding: ["comb", "honeycomb", "roast", "roasted", "glaze", "mustard"],
            options: [
                .init("maple", "Maple syrup", [.component("maple syrup", .same())], note: "Thinner and less sweet."),
                .init("golden-syrup", "Golden syrup", [.component("golden syrup", .same())], note: "Milder, with a buttery flavour.")
            ]
        ),
        SubstitutionRule(
            "maple-syrup",
            phrases: ["maple syrup"],
            options: [
                .init("honey", "Honey", [.component("honey", .same())], note: "Sweeter and thicker, and browns faster in the oven."),
                .init("golden-syrup", "Golden syrup", [.component("golden syrup", .same())], note: "Sweeter, without the maple flavour.")
            ]
        ),
        SubstitutionRule(
            "golden-syrup",
            phrases: ["golden syrup", "light corn syrup", "corn syrup"],
            options: [
                .init("honey", "Honey", [.component("honey", .same())], note: "More floral, and browns faster in the oven."),
                .init("maple", "Maple syrup", [.component("maple syrup", .same())], note: "Thinner, so flapjacks and toffee may set softer.")
            ]
        ),
        SubstitutionRule(
            "white-wine",
            phrases: ["white wine", "dry white wine"],
            excluding: ["vinegar"],
            options: [
                .init("stock-vinegar", "Stock and white wine vinegar", [
                    .component("chicken or vegetable stock", .measured(1 - sixteenth)),
                    .component("white wine vinegar", .measured(sixteenth))
                ], note: "For cooking, not for drinking-led dishes such as a sabayon.")
            ]
        ),
        SubstitutionRule(
            "red-wine",
            phrases: ["red wine", "dry red wine"],
            excluding: ["vinegar"],
            options: [
                .init("stock-vinegar", "Stock and red wine vinegar", [
                    .component("beef or vegetable stock", .measured(1 - sixteenth)),
                    .component("red wine vinegar", .measured(sixteenth))
                ], note: "Lighter in colour and body. A teaspoon of tomato purée adds back some depth.")
            ]
        ),
        SubstitutionRule(
            "stock",
            phrases: ["stock", "broth", "chicken stock", "vegetable stock", "beef stock"],
            excluding: ["cube", "powder", "pot", "bouillon", "granule"],
            options: [
                .init("cube", "Stock cube and water", [
                    .component("stock cube", .per(1, .count, references: [(500, .milliliter)])),
                    .component("boiling water", .measured(1))
                ], note: "Strengths vary by brand, so check the packet. Stock cubes are saltier; season at the end.")
            ]
        ),
        SubstitutionRule(
            "parmesan",
            phrases: ["parmesan", "parmigiano reggiano", "parmigiano"],
            options: [
                .init("grana-padano", "Grana Padano", [.component("Grana Padano", .same())], note: "Milder and slightly sweeter."),
                .init("pecorino", "Pecorino Romano", [.component("pecorino Romano", .same())], note: "Saltier and sharper, so taste before adding more salt.")
            ]
        ),
        SubstitutionRule(
            "pancetta",
            phrases: ["pancetta"],
            options: [
                .init("bacon", "Smoked streaky bacon", [.component("smoked streaky bacon", .same())], note: "Smokier; cut it into lardons.")
            ]
        )
    ]
}
