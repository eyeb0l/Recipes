import type { NormalizedRecipeSource } from "./types";

export const missingServingCountUncertaintyID = "missing-serving-count";
export const missingServingCountMessage = "The recipe doesn't say how many it serves, so the app shows 1.";

type JSONObject = Record<string, unknown>;

function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isMissingServingCountUncertainty(value: unknown): boolean {
  if (!isObject(value)) return false;
  if (value.id === missingServingCountUncertaintyID) return true;

  const wording = [value.message, value.sourceEvidence]
    .filter((item): item is string => typeof item === "string")
    .join(" ")
    .toLowerCase();
  const mentionsServingCount = /\b(?:yield|servings|serving count)\b/u.test(wording)
    || /\b(?:number of|how many|count of)\b[^.]{0,40}\b(?:serves?|portions?)\b/u.test(wording);
  const describesConflictingEvidence = /\b(?:ambiguous|unclear|conflicting|conflict|range|between|varies)\b/u.test(wording)
    || /\b\d+(?:\.\d+)?\s*(?:-|–|—|to|or)\s*\d+(?:\.\d+)?\b/u.test(wording);
  if (mentionsServingCount && describesConflictingEvidence) return false;
  const saysItIsMissing = /\b(?:missing|unknown|unstated|unspecified|placeholder)\b/u.test(wording)
    || /\b(?:does not|doesn't|did not|didn't|no)\b[^.]{0,60}\b(?:yield|servings?|serves?|portions?)\b/u.test(wording)
    || /\bhow many\b[^.]{0,40}\bserves?\b/u.test(wording)
    || /\b(?:shows?|set to|defaults? to)\s+(?:the\s+)?1\b/u.test(wording);
  return mentionsServingCount && saysItIsMissing;
}

function missingServingCountUncertainty(): JSONObject {
  return {
    id: missingServingCountUncertaintyID,
    kind: "other",
    severity: "warning",
    message: missingServingCountMessage,
    ingredientIDs: [],
    stageIDs: [],
    sourceEvidence: null,
    isResolved: false
  };
}

function usesMissingServingFallback(recipe: JSONObject): boolean {
  if (!isObject(recipe.yield)) return false;
  const label = recipe.yield.label;
  return recipe.yield.servings === 1 && (label === null || (typeof label === "string" && label.trim().length === 0));
}

/**
 * Resolves the canonical serving count in precedence order:
 * verified structured page data, the model result, then the model's explicit
 * 1/null fallback signal (which is normalized with a safe warning).
 */
export function resolveRecipeServingCount(recipe: JSONObject, source: NormalizedRecipeSource): void {
  const uncertainties = Array.isArray(recipe.uncertainties) ? recipe.uncertainties : undefined;
  const structured = source.structuredYield;
  if (structured && Number.isFinite(structured.servings) && structured.servings >= 1) {
    recipe.yield = { servings: structured.servings, label: structured.label };
    if (uncertainties) recipe.uncertainties = uncertainties.filter((item) => !isMissingServingCountUncertainty(item));
    return;
  }

  if (!uncertainties) return;
  const firstMissingIndex = uncertainties.findIndex(isMissingServingCountUncertainty);
  if (!usesMissingServingFallback(recipe)) {
    if (firstMissingIndex >= 0) {
      recipe.uncertainties = uncertainties.filter((item) => !isMissingServingCountUncertainty(item));
    }
    return;
  }

  recipe.yield = { servings: 1, label: null };
  const reconciled = uncertainties.filter((item) => !isMissingServingCountUncertainty(item));
  const insertionIndex = firstMissingIndex < 0 ? 0 : Math.min(firstMissingIndex, reconciled.length);
  reconciled.splice(insertionIndex, 0, missingServingCountUncertainty());
  recipe.uncertainties = reconciled;
}
