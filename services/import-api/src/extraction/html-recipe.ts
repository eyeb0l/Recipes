import { APIError } from "../errors";

export interface ExtractedPageRecipe {
  title?: string;
  ingredients: string[];
  instructions: string[];
  cleanedText: string;
  structuredYield?: { servings: number; label: string | null };
  pageText?: string;
  method: "json-ld" | "microdata" | "cleaned-prose";
  /** The language the page declares, such as "en-GB". A hint only: many sites keep their platform's default. */
  language?: string;
}

interface MicrodataRecipeCandidate {
  html: string;
  titles: string[];
  yieldValues: string[];
}

interface JSONLDRecipeCandidate {
  recipe: Record<string, unknown>;
  ingredients: string[];
  instructions: string[];
  title?: string;
  sourceIndex: number;
  score: number;
}

export function extractRecipeFromHTML(html: string): ExtractedPageRecipe {
  const extracted = extractPageRecipe(html);
  const language = declaredPageLanguage(html);
  return language ? { ...extracted, language } : extracted;
}

/** The first well-formed language tag from `<html lang>`, `og:locale`, or a `Content-Language` meta tag. */
export function declaredPageLanguage(html: string): string | undefined {
  const htmlAttributes = /<html\b([^>]*)>/iu.exec(html)?.[1] ?? "";
  const metaValues = (key: string) => Array.from(html.matchAll(/<meta\b([^>]*)>/giu), (match) => match[1] ?? "")
    .filter((attributes) => [attributeValue(attributes, "property"), attributeValue(attributes, "name"), attributeValue(attributes, "http-equiv")]
      .some((value) => value?.toLowerCase() === key))
    .map((attributes) => attributeValue(attributes, "content"));
  const candidates = [
    attributeValue(htmlAttributes, "lang"),
    attributeValue(htmlAttributes, "xml:lang"),
    ...metaValues("og:locale"),
    ...metaValues("content-language")
  ];
  for (const candidate of candidates) {
    const tag = candidate?.trim().replace(/_/gu, "-");
    if (tag && tag.length <= 35 && /^[a-z]{2,3}(?:-[a-z0-9]{1,8})*$/iu.test(tag)) return tag;
  }
  return undefined;
}

function extractPageRecipe(html: string): ExtractedPageRecipe {
  const visibleHTML = withoutInactiveHTML(html);
  const pageText = cleanHTML(visibleHTML);
  const microdataRecipeCandidates = extractMicrodataRecipeCandidates(visibleHTML);
  const jsonLD = extractJSONLD(html, pageText, microdataRecipeCandidates);
  if (jsonLD) return jsonLD;
  const microdata = extractMicrodata(pageText, microdataRecipeCandidates, extractHeadingTitles(visibleHTML));
  if (microdata) return microdata;
  if (pageText.length < 80 || isAccessChallenge(pageText)) {
    throw new APIError(422, "source_blocked", "The site did not expose readable recipe content. Paste its recipe text or scan the page instead.");
  }
  return { ingredients: [], instructions: [], cleanedText: pageText, pageText, method: "cleaned-prose" };
}

function extractJSONLD(html: string, pageText: string, microdataRecipeCandidates: MicrodataRecipeCandidate[]): ExtractedPageRecipe | undefined {
  const documents = jsonLDDocuments(html);
  const mainEntityIDs = new Set<string>();
  const mainEntityObjects = new WeakSet<object>();
  for (const document of documents) collectMainEntitySignals(document, mainEntityIDs, mainEntityObjects);

  const headingTitles = extractHeadingTitles(html).map(normalizeRecipeTitle).filter(Boolean);
  const candidates: JSONLDRecipeCandidate[] = [];
  let sourceIndex = 0;
  for (const document of documents) {
    for (const recipe of collectRecipeObjects(document)) {
      const ingredients = stringArray(recipe.recipeIngredient ?? recipe.ingredients);
      const instructions = instructionArray(recipe.recipeInstructions);
      if (ingredients.length === 0 && instructions.length === 0) continue;
      const title = textValue(recipe.name);
      const normalizedTitle = title ? normalizeRecipeTitle(title) : "";
      const recipeID = textValue(recipe["@id"]);
      const mainEntity = (recipeID ? mainEntityIDs.has(recipeID) : false)
        || mainEntityObjects.has(recipe)
        || recipe.mainEntityOfPage !== undefined;
      const headingMatch = Boolean(normalizedTitle && headingTitles.includes(normalizedTitle));
      const completeness = (ingredients.length > 0 && instructions.length > 0 ? 500 : 0)
        + Math.min(ingredients.length, 100) * 3
        + Math.min(instructions.length, 100) * 5;
      candidates.push({
        recipe,
        ingredients,
        instructions,
        title,
        sourceIndex,
        score: (mainEntity ? 10_000 : 0) + (headingMatch ? 5_000 : 0) + completeness
      });
      sourceIndex += 1;
    }
  }

  const selected = candidates.sort((left, right) => right.score - left.score || left.sourceIndex - right.sourceIndex)[0];
  if (!selected) return undefined;

  const { recipe, ingredients, instructions, title } = selected;
  const matchingMicrodataYieldValues = microdataYieldValuesForTitle(microdataRecipeCandidates, title);
  const jsonLDYield = parseStructuredYield(recipe.recipeYield);
  const structuredYield = jsonLDYield ?? parseStructuredYield(matchingMicrodataYieldValues);
  const jsonLDFallbackText = pageTextWithYieldEvidence(pageText, recipe.recipeYield);
  const fallbackPageText = jsonLDYield
    ? jsonLDFallbackText
    : pageTextWithYieldEvidence(jsonLDFallbackText ?? "", matchingMicrodataYieldValues);
  const yieldLabel = structuredYield?.label ?? (structuredYield ? String(structuredYield.servings) : undefined);
  const cleanedText = [
    title,
    yieldLabel ? "Yield" : undefined,
    yieldLabel,
    "Ingredients",
    ...ingredients,
    "Instructions",
    ...instructions
  ].filter(Boolean).join("\n");
  return {
    title,
    ingredients,
    instructions,
    cleanedText,
    structuredYield,
    pageText: fallbackPageText,
    method: "json-ld"
  };
}

function jsonLDDocuments(html: string): unknown[] {
  const inactiveRanges = inactiveHTMLRanges(html);
  const documents: unknown[] = [];
  let inactiveIndex = 0;
  const scripts = html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/giu);
  for (const match of scripts) {
    while (inactiveRanges[inactiveIndex] && inactiveRanges[inactiveIndex]!.end <= match.index) inactiveIndex += 1;
    const inactive = inactiveRanges[inactiveIndex];
    if (inactive && match.index >= inactive.start && match.index < inactive.end) continue;
    const type = attributeValue(match[1] ?? "", "type")?.split(";", 1)[0]?.trim().toLowerCase();
    if (type !== "application/ld+json") continue;
    const parsed = parseJSONLDPayload(match[2] ?? "");
    if (parsed !== undefined) documents.push(parsed);
    if (documents.length >= 256) break;
  }
  return documents;
}

function parseJSONLDPayload(value: string): unknown | undefined {
  const payload = value
    .trim()
    .replace(/^<!--\s*/u, "")
    .replace(/\s*-->$/u, "")
    .replace(/^<!\[CDATA\[\s*/u, "")
    .replace(/\s*\]\]>$/u, "")
    .replace(/;\s*$/u, "")
    .trim();
  if (!payload) return undefined;
  try {
    return JSON.parse(payload) as unknown;
  } catch {
    try {
      return JSON.parse(decodeEntities(payload)) as unknown;
    } catch {
      return undefined;
    }
  }
}

function collectRecipeObjects(value: unknown): Record<string, unknown>[] {
  const recipes: Record<string, unknown>[] = [];
  walkStructuredData(value, (object) => {
    if (hasSchemaType(object["@type"], "Recipe") && recipes.length < 256) recipes.push(object);
  });
  return recipes;
}

function collectMainEntitySignals(value: unknown, ids: Set<string>, objects: WeakSet<object>): void {
  walkStructuredData(value, (object) => {
    for (const key of ["mainEntity", "mainEntityOfPage"] as const) {
      const entity = object[key];
      for (const item of Array.isArray(entity) ? entity : [entity]) {
        if (typeof item === "string") ids.add(item);
        else if (item && typeof item === "object") {
          objects.add(item);
          const id = textValue((item as Record<string, unknown>)["@id"]);
          if (id) ids.add(id);
        }
      }
    }
  });
}

function walkStructuredData(value: unknown, visit: (object: Record<string, unknown>) => void): void {
  const seen = new WeakSet<object>();
  let remaining = 10_000;
  const walk = (current: unknown, depth: number): void => {
    if (remaining <= 0 || depth > 32 || !current || typeof current !== "object") return;
    if (seen.has(current)) return;
    seen.add(current);
    remaining -= 1;
    if (Array.isArray(current)) {
      for (const item of current.slice(0, 1_000)) walk(item, depth + 1);
      return;
    }
    const object = current as Record<string, unknown>;
    visit(object);
    for (const child of Object.values(object).slice(0, 1_000)) walk(child, depth + 1);
  };
  walk(value, 0);
}

function hasSchemaType(value: unknown, expected: string): boolean {
  const normalizedExpected = expected.toLowerCase();
  return stringArray(value).some((type) => {
    const normalized = type.trim().replace(/\/$/u, "").toLowerCase();
    return normalized === normalizedExpected
      || normalized === `https://schema.org/${normalizedExpected}`
      || normalized === `http://schema.org/${normalizedExpected}`;
  });
}

function textValue(value: unknown): string | undefined {
  if (typeof value === "string") return cleanText(value) || undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const languageValue = (value as Record<string, unknown>)["@value"];
  return typeof languageValue === "string" ? cleanText(languageValue) || undefined : undefined;
}

function extractHeadingTitles(html: string): string[] {
  const visibleHTML = withoutInactiveHTML(html)
    .replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/giu, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style\s*>/giu, " ")
    .replace(/<svg\b[^>]*>[\s\S]*?<\/svg\s*>/giu, " ");
  return [...visibleHTML.matchAll(/<h1\b[^>]*>([\s\S]*?)<\/h1\s*>/giu)]
    .map((match) => cleanHTML(match[1] ?? ""))
    .filter(Boolean)
    .slice(0, 20);
}

function isAccessChallenge(pageText: string): boolean {
  const normalized = pageText.toLowerCase();
  return normalized.includes("client challenge")
    || normalized.includes("please enable javascript to proceed")
    || normalized.includes("verify you are human")
    || normalized.includes("checking your browser before accessing")
    || (normalized.includes("just a moment") && normalized.includes("security of your connection"));
}

function stringArray(value: unknown): string[] {
  const values: string[] = [];
  const pending: Array<{ value: unknown; depth: number }> = [{ value, depth: 0 }];
  while (pending.length > 0 && values.length < 1_000) {
    const current = pending.pop()!;
    if (current.depth > 32) continue;
    if (typeof current.value === "string") {
      const text = cleanText(current.value);
      if (text) values.push(text);
    } else if (Array.isArray(current.value)) {
      for (const item of current.value.slice(0, 1_000).reverse()) pending.push({ value: item, depth: current.depth + 1 });
    } else {
      const text = textValue(current.value);
      if (text) values.push(text);
    }
  }
  return values;
}

function instructionArray(value: unknown): string[] {
  const instructions: string[] = [];
  const walk = (current: unknown, depth: number): void => {
    if (instructions.length >= 1_000 || depth > 32) return;
    if (typeof current === "string") {
      for (const line of current.split(/\n+/u).map(cleanText).filter(Boolean)) {
        if (instructions.length >= 1_000) break;
        instructions.push(line);
      }
      return;
    }
    if (Array.isArray(current)) {
      for (const item of current.slice(0, 1_000)) walk(item, depth + 1);
      return;
    }
    if (!current || typeof current !== "object") return;
    const object = current as Record<string, unknown>;
    const text = textValue(object.text ?? object["@value"]);
    if (text) instructions.push(text);
    else if (object.itemListElement) walk(object.itemListElement, depth + 1);
  };
  walk(value, 0);
  return instructions;
}

function extractMicrodata(pageText: string, candidates: MicrodataRecipeCandidate[], headingTitles: string[]): ExtractedPageRecipe | undefined {
  const normalizedHeadings = headingTitles.map(normalizeRecipeTitle).filter(Boolean);
  const recipes = candidates.map((candidate, sourceIndex) => {
    const ingredients = microdataPropertyValues(candidate.html, "recipeIngredient")
      .concat(microdataPropertyValues(candidate.html, "ingredients"))
      .flatMap(splitMicrodataListValue);
    const instructions = microdataPropertyValues(candidate.html, "recipeInstructions").flatMap(splitMicrodataListValue);
    const titleMatch = candidate.titles.some((title) => normalizedHeadings.includes(normalizeRecipeTitle(title)));
    return {
      candidate,
      sourceIndex,
      ingredients,
      instructions,
      score: (titleMatch ? 10_000 : 0) + (ingredients.length > 0 && instructions.length > 0 ? 500 : 0) + ingredients.length * 3 + instructions.length * 5
    };
  }).filter((recipe) => recipe.score > 0)
    .sort((left, right) => right.score - left.score || left.sourceIndex - right.sourceIndex);
  const selected = recipes[0];
  if (!selected) return undefined;

  const { candidate, ingredients, instructions } = selected;
  const structuredYield = parseStructuredYield(candidate.yieldValues);
  const title = candidate.titles[0];
  const yieldLabel = structuredYield?.label ?? (structuredYield ? String(structuredYield.servings) : undefined);
  return {
    title,
    ingredients,
    instructions,
    cleanedText: [
      title,
      yieldLabel ? "Yield" : undefined,
      yieldLabel,
      "Ingredients",
      ...ingredients,
      "Instructions",
      ...instructions
    ].filter(Boolean).join("\n"),
    structuredYield,
    pageText: pageTextWithYieldEvidence(pageText, candidate.yieldValues),
    method: "microdata"
  };
}

function splitMicrodataListValue(value: string): string[] {
  return value.split(/\n+/u).map(cleanText).filter(Boolean);
}

function microdataYieldValuesForTitle(candidates: MicrodataRecipeCandidate[], title: string | undefined): string[] {
  const normalizedTitle = title ? normalizeRecipeTitle(title) : "";
  if (!normalizedTitle) return [];
  return candidates
    .filter((candidate) => candidate.titles.some((candidateTitle) => normalizeRecipeTitle(candidateTitle) === normalizedTitle))
    .flatMap((candidate) => candidate.yieldValues);
}

function normalizeRecipeTitle(value: string): string {
  return cleanText(value).normalize("NFKC").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

function extractMicrodataRecipeCandidates(html: string): MicrodataRecipeCandidate[] {
  const scopes: Array<{ start: number; end: number }> = [];
  const stack: Array<{ tag: string; start: number; isRecipe: boolean }> = [];
  let ignoredTag: string | undefined;
  const tags = html.matchAll(/<(\/)?([a-z][\w:-]*)\b([^>]*)>/giu);
  const voidTags = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);

  for (const match of tags) {
    const closing = Boolean(match[1]);
    const tag = (match[2] ?? "").toLowerCase();
    if (ignoredTag) {
      if (closing && tag === ignoredTag) ignoredTag = undefined;
      continue;
    }
    if (!closing && new Set(["script", "style", "template"]).has(tag)) {
      ignoredTag = tag;
      continue;
    }
    if (!closing) {
      if (!voidTags.has(tag) && !/\/\s*>$/u.test(match[0])) {
        stack.push({ tag, start: match.index, isRecipe: isRecipeItemType(match[3] ?? "") });
      }
      continue;
    }

    let openingIndex = -1;
    for (let index = stack.length - 1; index >= 0; index -= 1) {
      if (stack[index]?.tag === tag) { openingIndex = index; break; }
    }
    if (openingIndex < 0) continue;
    const [opening] = stack.splice(openingIndex);
    if (!opening?.isRecipe) continue;
    if (scopes.length < 256) scopes.push({ start: opening.start, end: match.index + match[0].length });
  }
  return scopes.map((scope) => {
    const directHTML = withoutNestedRecipeScopes(html, scope, scopes);
    return {
      html: directHTML,
      titles: microdataPropertyValues(directHTML, "name"),
      yieldValues: microdataPropertyValues(directHTML, "recipeYield")
    };
  });
}

function withoutNestedRecipeScopes(html: string, outer: { start: number; end: number }, scopes: Array<{ start: number; end: number }>): string {
  const nested = scopes
    .filter((candidate) => candidate.start > outer.start && candidate.end < outer.end)
    .sort((left, right) => left.start - right.start || right.end - left.end)
    .filter((candidate, index, all) => !all.slice(0, index).some((parent) => candidate.start >= parent.start && candidate.end <= parent.end));
  if (nested.length === 0) return html.slice(outer.start, outer.end);
  const parts: string[] = [];
  let offset = outer.start;
  for (const range of nested) {
    parts.push(html.slice(offset, range.start), " ");
    offset = range.end;
  }
  parts.push(html.slice(offset, outer.end));
  return parts.join("");
}

function isRecipeItemType(attributes: string): boolean {
  const itemtype = attributeValue(attributes, "itemtype");
  return itemtype?.split(/\s+/u).some((value) => /(?:^|\/\/)(?:www\.)?schema\.org\/Recipe\/?$/iu.test(value)) ?? false;
}

function parseStructuredYield(value: unknown): { servings: number; label: string | null } | undefined {
  const entries = flattenYieldEntries(value);
  if (entries.length === 0) return undefined;

  const canonical = parseBareYieldCount(entries[0]);
  if (canonical) {
    let descriptiveLabel: string | null = null;
    for (const entry of entries.slice(1)) {
      const display = compatibleYieldDisplay(entry, canonical.servings);
      if (display.kind === "conflict") return undefined;
      if (!descriptiveLabel && display.kind === "compatible") descriptiveLabel = display.label;
    }
    return { servings: canonical.servings, label: descriptiveLabel ?? canonical.label };
  }

  const candidates = entries.map(parseYieldEntry);
  if (candidates.some((candidate) => !candidate)) return undefined;
  const resolved = candidates as Array<{ servings: number; label: string | null }>;
  const servings = resolved[0]?.servings;
  if (servings === undefined || resolved.some((candidate) => candidate.servings !== servings)) return undefined;
  return { servings, label: resolved.find((candidate) => candidate.label)?.label ?? null };
}

function flattenYieldEntries(value: unknown): unknown[] {
  const entries: unknown[] = [];
  const pending: Array<{ value: unknown; depth: number }> = [{ value, depth: 0 }];
  while (pending.length > 0 && entries.length < 100) {
    const current = pending.pop()!;
    if (current.depth > 32) continue;
    if (Array.isArray(current.value)) {
      for (const item of current.value.slice(0, 100).reverse()) pending.push({ value: item, depth: current.depth + 1 });
    } else if (current.value !== null && current.value !== undefined
      && !(typeof current.value === "string" && cleanText(current.value).length === 0)) {
      entries.push(current.value);
    }
  }
  return entries;
}

function parseBareYieldCount(value: unknown): { servings: number; label: string | null } | undefined {
  if (typeof value === "number") return validServingCount(value) ? { servings: value, label: null } : undefined;
  if (typeof value !== "string") return undefined;
  const label = cleanInlineText(value);
  if (!isBareNumber(label)) return undefined;
  const servings = Number(label.replaceAll(",", ""));
  return validServingCount(servings) ? { servings, label } : undefined;
}

function compatibleYieldDisplay(value: unknown, servings: number): { kind: "compatible"; label: string | null } | { kind: "neutral" | "conflict" } {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const parsed = parseYieldEntry(value);
    if (!parsed) return { kind: "conflict" };
    return parsed.servings === servings
      ? { kind: "compatible", label: parsed.label }
      : { kind: "conflict" };
  }
  const raw = rawYieldText(value);
  if (!raw) return { kind: "neutral" };
  const label = safeYieldLabel(raw);
  const leading = leadingYieldNumber(raw);
  if (leading !== undefined) {
    if (leadingNumberIsMeasurement(raw)) return { kind: "conflict" };
    return leading === servings
      ? { kind: "compatible", label }
      : { kind: "conflict" };
  }
  const parsed = parseYieldEntry(value);
  if (parsed) {
    return parsed.servings === servings
      ? { kind: "compatible", label: label ?? parsed.label }
      : { kind: "conflict" };
  }
  return containsNumericEvidence(raw) ? { kind: "conflict" } : { kind: "neutral" };
}

function parseYieldEntry(value: unknown): { servings: number; label: string | null } | undefined {
  if (typeof value === "number") return validServingCount(value) ? { servings: value, label: null } : undefined;
  if (typeof value === "string") return parseYieldLabel(value);
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;

  const object = value as Record<string, unknown>;
  const types = stringArray(object["@type"]);
  if (types.length > 0 && !hasSchemaType(object["@type"], "QuantitativeValue")) return undefined;
  if (!("value" in object) && !("name" in object)) return undefined;
  if (object.minValue !== undefined || object.maxValue !== undefined) return undefined;

  const unitCode = typeof object.unitCode === "string" ? normalizedUnitCode(object.unitCode) : "";
  if (unitCode && !new Set(["C62", "H87", "EA"]).has(unitCode)) return undefined;

  const valueCandidate = "value" in object ? parseStructuredYield(object.value) : undefined;
  const name = typeof object.name === "string" ? cleanInlineText(object.name) : "";
  const nameCandidate = name ? parseYieldLabel(name) : undefined;
  if ("value" in object && !valueCandidate) return undefined;
  if (name && !nameCandidate) return undefined;
  if (!valueCandidate && !nameCandidate) return undefined;
  if (valueCandidate && nameCandidate && valueCandidate.servings !== nameCandidate.servings) return undefined;

  const candidate = valueCandidate ?? nameCandidate!;
  const unitText = typeof object.unitText === "string" ? cleanInlineText(object.unitText) : "";
  if (unitText && (unitText.length > 100 || containsNumericEvidence(unitText) || hasNonCountUnit(unitText) || hasOpenEndedCount(unitText))) return undefined;

  let label = nameCandidate ? name : candidate.label;
  if (!label && unitText) label = `${candidate.servings} ${unitText}`;
  else if (label && unitText && isBareNumber(label)) label = `${label} ${unitText}`;
  if (label && (hasNonCountUnit(label) || hasOpenEndedCount(label))) return undefined;
  return { servings: candidate.servings, label: label || null };
}

function parseYieldLabel(value: string): { servings: number; label: string | null } | undefined {
  const label = cleanInlineText(value);
  if (!label || label.length > 200 || hasOpenEndedCount(label)) return undefined;
  const dimensioned = parseLeadingDimensionedYield(label);
  if (dimensioned !== undefined) {
    return { servings: dimensioned, label: safeYieldLabel(value) };
  }
  if (hasNonCountUnit(label)) return undefined;
  const tokens = numericTokens(label);
  if (tokens.length !== 1) return undefined;
  const servings = Number(tokens[0]!.replaceAll(",", ""));
  return validServingCount(servings) ? { servings, label: safeYieldLabel(value) } : undefined;
}

function parseLeadingDimensionedYield(label: string): number | undefined {
  const match = label.match(/^(?:(?:yield(?:s)?|makes?|serves?|about|approximately|approx(?:imately)?\.?|roughly|around|produces?)\b[\s:,-]*)*([-+]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)/iu);
  if (!match?.[1]) return undefined;
  const servings = Number(match[1].replaceAll(",", ""));
  if (!validServingCount(servings)) return undefined;
  const suffix = label.slice(match[0].length);
  if (!suffix.trim()) return servings;
  if (isDirectMeasurementSuffix(suffix)) return undefined;

  const withoutDimensions = suffix.replace(sizedQuantityPattern(), " ");
  if (containsNumericEvidence(withoutDimensions)) return undefined;
  return /\p{L}/u.test(withoutDimensions) ? servings : undefined;
}

function leadingYieldNumber(value: string): number | undefined {
  const label = cleanInlineText(value);
  const match = label.match(/^(?:(?:yield(?:s)?|makes?|serves?|about|approximately|approx(?:imately)?\.?|roughly|around|produces?)\b[\s:,-]*)*([-+]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)/iu);
  if (!match?.[1]) return undefined;
  const servings = Number(match[1].replaceAll(",", ""));
  return validServingCount(servings) ? servings : undefined;
}

function leadingNumberIsMeasurement(value: string): boolean {
  const label = cleanInlineText(value);
  const match = label.match(/^(?:(?:yield(?:s)?|makes?|serves?|about|approximately|approx(?:imately)?\.?|roughly|around|produces?)\b[\s:,-]*)*[-+]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?/iu);
  return Boolean(match && isDirectMeasurementSuffix(label.slice(match[0].length)));
}

function isDirectMeasurementSuffix(value: string): boolean {
  return new RegExp(`^\\s*[\\[(]?\\s*(?:[\\u00BC-\\u00BE\\u2150-\\u215E]|\\/\\s*\\d|[-\u2013\u2014]?\\s*${measurementUnitSource}(?![\\p{L}\\p{N}]))`, "iu").test(value);
}

const measurementUnitSource = "(?:inch(?:es)?|in\\.?|millimet(?:er|re)s?|mms?|centimet(?:er|re)s?|cms?|metres?|meters?|m|micrograms?|µg|milligrams?|mg|grams?|grammes?|gms?|g|kilograms?|kgs?|kg|millilit(?:er|re)s?|mls?|ml|cl|dl|lit(?:er|re)s?|ltrs?|l|cc|fluid\\s+ounces?|fl\\s*oz|ounces?|oz|pounds?|lb|lbs|cups?|pints?|quarts?|gallons?|tablespoons?|tbsp|teaspoons?|tsp|calories?|kilocalories?|kcal|kilojoules?|kj|seconds?|secs?|minutes?|mins?|hours?|hrs?)";
const sizedNumberSource = "(?:\\d+(?:\\.\\d+)?(?:\\s+\\d+\\/\\d+)?|\\d+[\\u00BC-\\u00BE\\u2150-\\u215E]|[\\u00BC-\\u00BE\\u2150-\\u215E])";

function sizedQuantityPattern(): RegExp {
  return new RegExp(`${sizedNumberSource}(?:\\s*[x\u00D7]\\s*${sizedNumberSource})*\\s*(?:[-\u2013\u2014]\\s*)?${measurementUnitSource}(?![\\p{L}\\p{N}])`, "giu");
}

function containsNumericEvidence(value: string): boolean {
  return /\d|[\u00BC-\u00BE\u2150-\u215E]/u.test(value);
}

function safeYieldLabel(value: string): string | null {
  if (/[\r\n\u2028\u2029]/u.test(value)) return null;
  const label = cleanInlineText(value);
  return label.length > 0 && label.length <= 200 ? label : null;
}

function cleanInlineText(value: string): string {
  return cleanText(value).replace(/\s+/gu, " ").trim();
}

function normalizedUnitCode(value: string): string {
  return cleanInlineText(value).split(/[\/#:]/u).filter(Boolean).at(-1)?.toUpperCase() ?? "";
}

function numericTokens(value: string): string[] {
  if (/[\u00BC-\u00BE\u2150-\u215E]/u.test(value)) return [];
  return value.match(/[-+]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|[-+]?\.\d+/gu) ?? [];
}

function validServingCount(value: number): boolean {
  return Number.isFinite(value) && value >= 1;
}

function hasOpenEndedCount(value: string): boolean {
  return /\b(?:up to|at least|at most|more than|less than|over|under|minimum|maximum|dozens?|scores?|pairs?)\b|\d\s*\+|\bor more\b/iu.test(value);
}

function hasNonCountUnit(value: string): boolean {
  return /%|°|\b(?:inch(?:es)?|millimet(?:er|re)s?|mms?|centimet(?:er|re)s?|cms?|metres?|meters?|µg|milligrams?|mg|grams?|grammes?|gms?|g|kilograms?|kgs?|kg|millilit(?:er|re)s?|mls?|ml|cl|dl|lit(?:er|re)s?|ltrs?|l|cc|fluid ounces?|ounces?|oz|pounds?|lb|lbs|cups?|pints?|quarts?|gallons?|tablespoons?|tbsp|teaspoons?|tsp|calories?|kilocalories?|kcal|kilojoules?|kj|seconds?|secs?|minutes?|mins?|hours?|hrs?)\b|\d\s*(?:in|mms?|cms?|µg|mg|gms?|g|kgs?|kg|mls?|ml|cl|dl|ltrs?|l|cc|fl\s*oz|oz|lb|lbs|tbsp|tsp|kcal|kj|secs?|mins?|hrs?)\b/iu.test(value);
}

function isBareNumber(value: string): boolean {
  return /^[-+]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?$/u.test(value);
}

function pageTextWithYieldEvidence(pageText: string, value: unknown): string | undefined {
  const yieldText = rawYieldText(value);
  if (!yieldText) return pageText || undefined;
  return [`Recipe yield: ${yieldText}`, pageText].filter(Boolean).join("\n");
}

function rawYieldText(value: unknown): string | undefined {
  const parts = rawYieldParts(value)
    .map((part) => cleanText(part).slice(0, 500))
    .filter(Boolean);
  const unique = parts.filter((part, index) => parts.findIndex((candidate) => candidate.toLowerCase() === part.toLowerCase()) === index);
  return unique.join(" | ").slice(0, 2_000) || undefined;
}

function rawYieldParts(value: unknown, depth = 0): string[] {
  if (depth > 16) return [];
  if (Array.isArray(value)) return value.slice(0, 100).flatMap((item) => rawYieldParts(item, depth + 1));
  if (typeof value === "string") return [value];
  if (typeof value === "number") return Number.isFinite(value) ? [String(value)] : [];
  if (!value || typeof value !== "object") return [];

  const object = value as Record<string, unknown>;
  const name = typeof object.name === "string" ? cleanText(object.name) : "";
  const unitText = typeof object.unitText === "string" ? cleanText(object.unitText) : "";
  const values = rawYieldParts(object.value, depth + 1);
  const quantified = values.map((part) => appendUnitText(part, unitText));
  const minimum = rawYieldParts(object.minValue, depth + 1)[0];
  const maximum = rawYieldParts(object.maxValue, depth + 1)[0];
  const range = minimum && maximum
    ? `${minimum}\u2013${maximum}${unitText ? ` ${unitText}` : ""}`
    : minimum
      ? `minimum ${minimum}${unitText ? ` ${unitText}` : ""}`
      : maximum
        ? `maximum ${maximum}${unitText ? ` ${unitText}` : ""}`
        : "";
  return [name, ...quantified, range].filter(Boolean);
}

function appendUnitText(value: string, unitText: string): string {
  if (!unitText || value.toLowerCase().includes(unitText.toLowerCase())) return value;
  return `${value} ${unitText}`;
}

function microdataPropertyValues(html: string, property: string): string[] {
  const values: Array<{ index: number; value: string }> = [];
  const stack: Array<{ tag: string; innerStart: number; attributes: string; index: number; matches: boolean }> = [];
  const voidTags = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);
  let ignoredTag: string | undefined;
  for (const match of html.matchAll(/<(\/)?([a-z][\w:-]*)\b([^>]*)>/giu)) {
    if (values.length >= 1_000) break;
    const closing = Boolean(match[1]);
    const tag = (match[2] ?? "").toLowerCase();
    if (ignoredTag) {
      if (closing && tag === ignoredTag) ignoredTag = undefined;
      continue;
    }
    if (!closing && new Set(["script", "style"]).has(tag)) {
      ignoredTag = tag;
      continue;
    }
    if (!closing) {
      const attributes = match[3] ?? "";
      const matches = hasItemprop(attributes, property);
      if (voidTags.has(tag) || /\/\s*>$/u.test(match[0])) {
        if (matches) {
          const value = microdataTagValue(tag, attributes, "");
          if (value) values.push({ index: match.index, value });
        }
      } else if (stack.length < 512) {
        stack.push({ tag, innerStart: match.index + match[0].length, attributes, index: match.index, matches });
      }
      continue;
    }

    let openingIndex = -1;
    for (let index = stack.length - 1; index >= 0; index -= 1) {
      if (stack[index]?.tag === tag) { openingIndex = index; break; }
    }
    if (openingIndex < 0) continue;
    const [opening] = stack.splice(openingIndex);
    if (!opening?.matches) continue;
    const value = microdataTagValue(tag, opening.attributes, html.slice(opening.innerStart, match.index));
    if (value) values.push({ index: opening.index, value });
  }
  return values.sort((left, right) => left.index - right.index).map((item) => item.value);
}

function microdataTagValue(tag: string, attributes: string, innerHTML: string): string {
  const normalizedTag = tag.toLowerCase();
  const attributeName = new Map<string, string>([
    ["meta", "content"], ["audio", "src"], ["embed", "src"], ["iframe", "src"],
    ["img", "src"], ["source", "src"], ["track", "src"], ["video", "src"],
    ["a", "href"], ["area", "href"], ["link", "href"], ["object", "data"],
    ["data", "value"], ["meter", "value"], ["time", "datetime"]
  ]).get(normalizedTag);
  const explicit = attributeValue(attributes, "content") ?? (attributeName ? attributeValue(attributes, attributeName) : undefined);
  return explicit === undefined ? cleanHTML(innerHTML) : cleanText(explicit);
}

function hasItemprop(attributes: string, property: string): boolean {
  const itemprop = attributeValue(attributes, "itemprop");
  return itemprop?.split(/\s+/u).some((token) => token.toLowerCase() === property.toLowerCase()) ?? false;
}

function attributeValue(attributes: string, name: string): string | undefined {
  const pattern = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'=<>]+))`, "iu");
  const match = attributes.match(pattern);
  return match?.[1] ?? match?.[2] ?? match?.[3];
}

export function cleanHTML(html: string): string {
  return cleanText(withoutInactiveHTML(html)
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/giu, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/giu, " ")
    .replace(/<svg\b[^>]*>[\s\S]*?<\/svg>/giu, " ")
    .replace(/<(?:br|\/p|\/li|\/h[1-6]|\/section|\/div)>/giu, "\n")
    .replace(/<[^>]+>/gu, " "));
}

function withoutInactiveHTML(html: string): string {
  const ranges = inactiveHTMLRanges(html);
  if (ranges.length === 0) return html;
  const parts: string[] = [];
  let offset = 0;
  for (const range of ranges) {
    parts.push(html.slice(offset, range.start), " ");
    offset = range.end;
  }
  parts.push(html.slice(offset));
  return parts.join("");
}

function inactiveHTMLRanges(html: string): Array<{ start: number; end: number }> {
  const comments = [...html.matchAll(/<!--[\s\S]*?-->/gu)]
    .map((match) => ({ start: match.index, end: match.index + match[0].length }));
  const scripts = [...html.matchAll(/<script\b[^>]*>[\s\S]*?<\/script\s*>/giu)]
    .map((match) => ({ start: match.index, end: match.index + match[0].length }));
  const protectedRanges = [...comments, ...scripts].sort((left, right) => left.start - right.start);
  const templates: Array<{ start: number; end: number }> = [];
  let protectedIndex = 0;
  let depth = 0;
  let start = -1;
  for (const match of html.matchAll(/<(\/)?template\b[^>]*>/giu)) {
    while (protectedRanges[protectedIndex] && protectedRanges[protectedIndex]!.end <= match.index) protectedIndex += 1;
    const protectedRange = protectedRanges[protectedIndex];
    if (protectedRange && match.index >= protectedRange.start && match.index < protectedRange.end) continue;
    if (!match[1]) {
      if (depth === 0) start = match.index;
      depth += 1;
    } else if (depth > 0) {
      depth -= 1;
      if (depth === 0 && start >= 0) {
        templates.push({ start, end: match.index + match[0].length });
        start = -1;
      }
    }
  }
  if (depth > 0 && start >= 0) templates.push({ start, end: html.length });
  const ranges = [...comments, ...templates].sort((left, right) => left.start - right.start || right.end - left.end);
  const merged: Array<{ start: number; end: number }> = [];
  for (const range of ranges) {
    const previous = merged.at(-1);
    if (previous && range.start <= previous.end) previous.end = Math.max(previous.end, range.end);
    else merged.push({ ...range });
  }
  return merged;
}

function cleanText(value: string): string {
  return decodeEntities(value)
    .replace(/[\t\r ]+/gu, " ")
    .replace(/ *\n */gu, "\n")
    .replace(/\n{3,}/gu, "\n\n")
    .trim();
}

function decodeEntities(value: string): string {
  const named: Record<string, string> = {
    amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ",
    frac12: "½", frac14: "¼", frac34: "¾", frac13: "⅓", frac23: "⅔",
    frac15: "⅕", frac25: "⅖", frac35: "⅗", frac45: "⅘", frac16: "⅙",
    frac56: "⅚", frac18: "⅛", frac38: "⅜", frac58: "⅝", frac78: "⅞"
  };
  return value.replace(/&(#x?[0-9a-f]+|[a-z][a-z0-9]+);/giu, (match, entity: string) => {
    if (entity.startsWith("#x") || entity.startsWith("#X")) return safeCodePoint(Number.parseInt(entity.slice(2), 16));
    if (entity.startsWith("#")) return safeCodePoint(Number.parseInt(entity.slice(1), 10));
    return named[entity.toLowerCase()] ?? match;
  });
}

function safeCodePoint(value: number): string {
  if (!Number.isInteger(value) || value < 0 || value > 0x10_FFFF || (value >= 0xD800 && value <= 0xDFFF)) return "�";
  return String.fromCodePoint(value);
}
