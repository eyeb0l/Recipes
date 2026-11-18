type JSONObject = Record<string, unknown>;
type MeasureSystem = "us" | "imperial";

/** Millilitres in each RecipeV1 unit that differs between US customary and UK imperial measures. */
const millilitersPerUnit = {
  pint: 473.176473,
  fluidOunce: 29.5735295625,
  imperialPint: 568.26125,
  imperialFluidOunce: 28.4130625
} as const;

type SystemDependentUnit = keyof typeof millilitersPerUnit;

const units: Record<SystemDependentUnit, { system: MeasureSystem; family: "pint" | "fluidOunce" }> = {
  pint: { system: "us", family: "pint" },
  fluidOunce: { system: "us", family: "fluidOunce" },
  imperialPint: { system: "imperial", family: "pint" },
  imperialFluidOunce: { system: "imperial", family: "fluidOunce" }
};

const unitFor: Record<"pint" | "fluidOunce", Record<MeasureSystem, SystemDependentUnit>> = {
  pint: { us: "pint", imperial: "imperialPint" },
  fluidOunce: { us: "fluidOunce", imperial: "imperialFluidOunce" }
};

/**
 * The RecipeV1 units app builds understood before UK imperial units were added. Builds that
 * don't send `supportedUnits` can decode only these.
 */
export const legacyUnitIDs: readonly string[] = [
  "none", "gram", "kilogram", "ounce", "pound",
  "milliliter", "liter", "teaspoon", "tablespoon", "cup", "fluidOunce", "pint",
  "celsius", "fahrenheit",
  "count", "pinch", "clove", "slice", "can", "package", "bunch", "sprig", "shot"
];

function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSystemDependentUnit(value: unknown): value is SystemDependentUnit {
  return typeof value === "string" && Object.hasOwn(units, value);
}

/** Every quantity in the recipe, each with the quantity of the ingredient it allocates, if any. */
function quantities(recipe: JSONObject): Array<{ quantity: JSONObject; ingredientQuantity?: JSONObject }> {
  const result: Array<{ quantity: JSONObject; ingredientQuantity?: JSONObject }> = [];
  const ingredientQuantities = new Map<string, JSONObject>();
  for (const ingredient of Array.isArray(recipe.ingredients) ? recipe.ingredients : []) {
    if (!isObject(ingredient) || !isObject(ingredient.quantity)) continue;
    result.push({ quantity: ingredient.quantity });
    if (typeof ingredient.id === "string") ingredientQuantities.set(ingredient.id, ingredient.quantity);
  }
  for (const stage of Array.isArray(recipe.stages) ? recipe.stages : []) {
    if (!isObject(stage) || !Array.isArray(stage.ingredientUses)) continue;
    for (const use of stage.ingredientUses) {
      if (!isObject(use) || !isObject(use.quantity)) continue;
      const ingredientQuantity = typeof use.ingredientID === "string" ? ingredientQuantities.get(use.ingredientID) : undefined;
      result.push({ quantity: use.quantity, ingredientQuantity });
    }
  }
  return result;
}

const unitWords = String.raw`(?:pints?|pts?\.?|fl\.?\s*oz\.?|fluid\s+ounces?)`;
const imperialLabel = new RegExp(String.raw`\b(?:uk|u\.k\.|british|imperial)\s+${unitWords}(?![\p{L}\p{N}])|${unitWords}\s*\(\s*(?:uk|imperial)\s*\)`, "iu");
const usLabel = new RegExp(String.raw`\b(?:us|u\.s\.|american)\s+${unitWords}(?![\p{L}\p{N}])|${unitWords}\s*\(\s*(?:us|u\.s\.)\s*\)`, "iu");

/** A system named in the quantity's own wording, such as "1 UK pint" or "10 US fl oz". */
function labelledSystem(text: string): MeasureSystem | undefined {
  const imperial = imperialLabel.test(text);
  const us = usLabel.test(text);
  if (imperial === us) return undefined;
  return imperial ? "imperial" : "us";
}

const metricAmount = /(\d+(?:[.,]\d+)*)\s*(ml|millilit(?:re|er)s?|cl|centilit(?:re|er)s?|l|lit(?:re|er)s?|ltrs?)(?![\p{L}\p{N}])/giu;

function parseDecimal(value: string): number {
  // "1,200" is a thousands separator; "1,2" is a decimal comma.
  const normalized = /,\d{3}(?:\D|$)/u.test(value) ? value.replace(/,/gu, "") : value.replace(/,/gu, ".");
  return Number(normalized);
}

/**
 * The system implied by a single metric equivalent written beside pints, such as "½ pint (300 ml)".
 * UK recipes round a pint to 568–600 ml and US recipes to 473–500 ml, so the two never come within 8%
 * of the other's size. Fluid ounces differ by only 4%, less than recipes round by, so they are not judged this way.
 */
function metricEquivalentSystem(quantity: JSONObject, text: string): MeasureSystem | undefined {
  if (quantity.kind !== "exact" || typeof quantity.value !== "number" || quantity.value <= 0) return undefined;
  const amounts = Array.from(text.matchAll(metricAmount));
  if (amounts.length !== 1) return undefined;
  const [, number, unit] = amounts[0]!;
  const lowerUnit = unit!.toLowerCase();
  const scale = lowerUnit.startsWith("m") ? 1 : lowerUnit.startsWith("c") ? 10 : 1_000;
  const perPint = parseDecimal(number!) * scale / quantity.value;
  if (!Number.isFinite(perPint)) return undefined;
  if (Math.abs(perPint / millilitersPerUnit.imperialPint - 1) <= 0.08) return "imperial";
  if (Math.abs(perPint / millilitersPerUnit.pint - 1) <= 0.08) return "us";
  return undefined;
}

function evidencedSystem(quantity: JSONObject, family: "pint" | "fluidOunce"): MeasureSystem | undefined {
  const text = typeof quantity.originalText === "string" ? quantity.originalText : "";
  if (!text) return undefined;
  return labelledSystem(text) ?? (family === "pint" ? metricEquivalentSystem(quantity, text) : undefined);
}

/**
 * Corrects US and UK pints and fluid ounces where the source settles which one it means.
 *
 * The model chooses between `pint` and `imperialPint` from the whole source. This pass only
 * overrides it with evidence in a quantity's own wording: an explicit "UK pint" or "US pint", or a
 * metric equivalent that matches one pint size. A stage's allocation that gives no evidence of its
 * own follows its ingredient, so "1 UK pint milk" and "add the milk, 10 fl oz at a time" agree.
 * Everything else, including any uncertainty the model recorded, is left as it is.
 */
export function reconcileSystemDependentUnits(recipe: JSONObject): void {
  const entries = quantities(recipe);
  const evidenced = new Set<JSONObject>();
  for (const { quantity } of entries) {
    if (!isSystemDependentUnit(quantity.unit)) continue;
    const { family } = units[quantity.unit];
    const system = evidencedSystem(quantity, family);
    if (!system) continue;
    quantity.unit = unitFor[family][system];
    evidenced.add(quantity);
  }
  for (const { quantity, ingredientQuantity } of entries) {
    if (!ingredientQuantity || evidenced.has(quantity) || !isSystemDependentUnit(quantity.unit) || !isSystemDependentUnit(ingredientQuantity.unit)) continue;
    quantity.unit = unitFor[units[quantity.unit].family][units[ingredientQuantity.unit].system];
  }
}

/** Units that older builds can't decode, and the supported unit each is rewritten in. */
const fallbacks: Record<string, { unit: string; factor: number }> = {
  imperialPint: { unit: "milliliter", factor: millilitersPerUnit.imperialPint },
  imperialFluidOunce: { unit: "milliliter", factor: millilitersPerUnit.imperialFluidOunce }
};

function roundedMilliliters(value: number): number {
  // Whole millilitres are finer than a measuring jug reads; keep a decimal for very small amounts.
  return value >= 10 ? Math.round(value) : Math.round(value * 10) / 10;
}

/**
 * Rewrites quantities in units the requesting build can't decode into millilitres, so a build
 * released before UK pints were added still gets the right amount rather than a decoding failure.
 * `originalText` keeps the source wording, such as "1 pint".
 */
export function adaptRecipeUnitsForClient(recipe: JSONObject, supportedUnits: readonly string[] | undefined): void {
  const supported = new Set(supportedUnits ?? legacyUnitIDs);
  for (const { quantity } of quantities(recipe)) {
    if (typeof quantity.unit !== "string" || supported.has(quantity.unit)) continue;
    const fallback = fallbacks[quantity.unit];
    if (!fallback || !supported.has(fallback.unit)) continue;
    for (const key of ["value", "lower", "upper"] as const) {
      const amount = quantity[key];
      if (typeof amount === "number") quantity[key] = roundedMilliliters(amount * fallback.factor);
    }
    quantity.unit = fallback.unit;
  }
}
