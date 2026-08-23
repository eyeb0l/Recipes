import { APIError } from "../errors";

export interface ExtractedPageRecipe {
  title?: string;
  ingredients: string[];
  instructions: string[];
  cleanedText: string;
  structuredYield?: { servings: number; label: string | null };
  pageText?: string;
  method: "json-ld" | "microdata" | "cleaned-prose";
}

interface MicrodataRecipeCandidate {
  html: string;
  titles: string[];
  yieldValues: string[];
}

export function extractRecipeFromHTML(html: string): ExtractedPageRecipe {
  const pageText = cleanHTML(html);
  const microdataRecipeCandidates = extractMicrodataRecipeCandidates(html);
  const jsonLD = extractJSONLD(html, pageText, microdataRecipeCandidates);
  if (jsonLD) return jsonLD;
  const microdata = extractMicrodata(pageText, microdataRecipeCandidates);
  if (microdata) return microdata;
  if (pageText.length < 80) {
    throw new APIError(422, "source_blocked", "The site did not expose readable recipe content. Paste its recipe text or scan the page instead.");
  }
  return { ingredients: [], instructions: [], cleanedText: pageText, pageText, method: "cleaned-prose" };
}

function extractJSONLD(html: string, pageText: string, microdataRecipeCandidates: MicrodataRecipeCandidate[]): ExtractedPageRecipe | undefined {
  const scripts = html.matchAll(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/giu);
  for (const match of scripts) {
    try {
      const parsed: unknown = JSON.parse(decodeEntities(match[1] ?? "").trim());
      const recipe = findRecipe(parsed);
      if (!recipe) continue;
      const ingredients = stringArray(recipe.recipeIngredient);
      const instructions = instructionArray(recipe.recipeInstructions);
      const title = typeof recipe.name === "string" ? recipe.name.trim() : undefined;
      const matchingMicrodataYieldValues = microdataYieldValuesForTitle(microdataRecipeCandidates, title);
      const jsonLDYield = parseStructuredYield(recipe.recipeYield);
      const structuredYield = jsonLDYield ?? parseStructuredYield(matchingMicrodataYieldValues);
      const jsonLDFallbackText = pageTextWithYieldEvidence(pageText, recipe.recipeYield);
      const fallbackPageText = jsonLDYield
        ? jsonLDFallbackText
        : pageTextWithYieldEvidence(jsonLDFallbackText ?? "", matchingMicrodataYieldValues);
      if (ingredients.length === 0 && instructions.length === 0) continue;
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
    } catch {
      // Malformed JSON-LD is common; continue into microdata and cleaned-prose layers.
    }
  }
  return undefined;
}

function findRecipe(value: unknown): Record<string, unknown> | undefined {
  if (Array.isArray(value)) {
    for (const item of value) { const found = findRecipe(item); if (found) return found; }
    return undefined;
  }
  if (!value || typeof value !== "object") return undefined;
  const object = value as Record<string, unknown>;
  const types = stringArray(object["@type"]);
  if (types.some((type) => type.toLowerCase() === "recipe")) return object;
  for (const child of Object.values(object)) { const found = findRecipe(child); if (found) return found; }
  return undefined;
}

function stringArray(value: unknown): string[] {
  if (typeof value === "string") return [cleanText(value)].filter(Boolean);
  if (Array.isArray(value)) return value.flatMap(stringArray);
  return [];
}

function instructionArray(value: unknown): string[] {
  if (typeof value === "string") return value.split(/\n+/u).map(cleanText).filter(Boolean);
  if (Array.isArray(value)) return value.flatMap(instructionArray);
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    if (typeof object.text === "string") return [cleanText(object.text)].filter(Boolean);
    if (object.itemListElement) return instructionArray(object.itemListElement);
  }
  return [];
}

function extractMicrodata(pageText: string, candidates: MicrodataRecipeCandidate[]): ExtractedPageRecipe | undefined {
  const recipes = candidates.map((candidate, sourceIndex) => {
    const ingredients = [...candidate.html.matchAll(/<[^>]+itemprop=["'](?:recipeIngredient|ingredients)["'][^>]*>([\s\S]*?)<\/[^>]+>/giu)]
      .map((match) => cleanHTML(match[1] ?? "")).filter(Boolean);
    const instructions = [...candidate.html.matchAll(/<[^>]+itemprop=["']recipeInstructions["'][^>]*>([\s\S]*?)<\/[^>]+>/giu)]
      .map((match) => cleanHTML(match[1] ?? "")).filter(Boolean);
    return { candidate, sourceIndex, ingredients, instructions, score: ingredients.length + instructions.length };
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
  const candidates: MicrodataRecipeCandidate[] = [];
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
    const scope = html.slice(opening.start, match.index + match[0].length);
    if (countRecipeItemTypes(scope) !== 1) continue;
    const titles = microdataPropertyValues(scope, "name");
    const yieldValues = microdataPropertyValues(scope, "recipeYield");
    candidates.push({ html: scope, titles, yieldValues });
  }
  return candidates;
}

function countRecipeItemTypes(html: string): number {
  return [...html.matchAll(/<([a-z][\w:-]*)\b([^>]*)>/giu)]
    .filter((match) => isRecipeItemType(match[2] ?? "")).length;
}

function isRecipeItemType(attributes: string): boolean {
  const itemtype = attributeValue(attributes, "itemtype");
  return itemtype?.split(/\s+/u).some((value) => /(?:^|\/\/)(?:www\.)?schema\.org\/Recipe\/?$/iu.test(value)) ?? false;
}

function parseStructuredYield(value: unknown): { servings: number; label: string | null } | undefined {
  const entries = flattenYieldEntries(value);
  if (entries.length === 0) return undefined;

  const candidates = entries.map(parseYieldEntry);
  if (candidates.some((candidate) => !candidate)) return undefined;
  const resolved = candidates as Array<{ servings: number; label: string | null }>;
  const servings = resolved[0]?.servings;
  if (servings === undefined || resolved.some((candidate) => candidate.servings !== servings)) return undefined;
  return { servings, label: resolved.find((candidate) => candidate.label)?.label ?? null };
}

function flattenYieldEntries(value: unknown): unknown[] {
  if (Array.isArray(value)) return value.flatMap(flattenYieldEntries);
  if (value === null || value === undefined) return [];
  if (typeof value === "string" && cleanText(value).length === 0) return [];
  return [value];
}

function parseYieldEntry(value: unknown): { servings: number; label: string | null } | undefined {
  if (typeof value === "number") return validServingCount(value) ? { servings: value, label: null } : undefined;
  if (typeof value === "string") return parseYieldLabel(value);
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;

  const object = value as Record<string, unknown>;
  const types = stringArray(object["@type"]);
  if (types.length > 0 && !types.some((type) => type.toLowerCase() === "quantitativevalue")) return undefined;
  if (!("value" in object) && !("name" in object)) return undefined;
  if (object.minValue !== undefined || object.maxValue !== undefined) return undefined;

  const valueCandidate = "value" in object ? parseStructuredYield(object.value) : undefined;
  const name = typeof object.name === "string" ? cleanText(object.name) : "";
  const nameCandidate = name ? parseYieldLabel(name) : undefined;
  if ("value" in object && !valueCandidate) return undefined;
  if (!valueCandidate && !nameCandidate) return undefined;
  if (valueCandidate && nameCandidate && valueCandidate.servings !== nameCandidate.servings) return undefined;

  const candidate = valueCandidate ?? nameCandidate!;
  const unitText = typeof object.unitText === "string" ? cleanText(object.unitText) : "";
  if (unitText && (unitText.length > 100 || numericTokens(unitText).length > 0 || hasNonCountUnit(unitText))) return undefined;

  let label = nameCandidate ? name : candidate.label;
  if (!label && unitText) label = `${candidate.servings} ${unitText}`;
  else if (label && unitText && isBareNumber(label)) label = `${label} ${unitText}`;
  if (label && hasNonCountUnit(label)) return undefined;
  return { servings: candidate.servings, label: label || null };
}

function parseYieldLabel(value: string): { servings: number; label: string } | undefined {
  const label = cleanText(value);
  if (!label || label.length > 200 || hasNonCountUnit(label) || hasOpenEndedCount(label)) return undefined;
  const tokens = numericTokens(label);
  if (tokens.length !== 1) return undefined;
  const servings = Number(tokens[0]!.replaceAll(",", ""));
  return validServingCount(servings) ? { servings, label } : undefined;
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
  return /%|°|\b(?:µg|milligrams?|mg|grams?|g|kilograms?|kg|millilit(?:er|re)s?|ml|cl|dl|lit(?:er|re)s?|l|cc|fluid ounces?|ounces?|oz|pounds?|lb|lbs|cups?|pints?|quarts?|gallons?|tablespoons?|tbsp|teaspoons?|tsp|calories?|kilocalories?|kcal|kilojoules?|kj|seconds?|secs?|minutes?|mins?|hours?|hrs?)\b|\d\s*(?:µg|mg|g|kg|ml|cl|dl|l|cc|fl\s*oz|oz|lb|lbs|tbsp|tsp|kcal|kj|secs?|mins?|hrs?)\b/iu.test(value);
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

function rawYieldParts(value: unknown): string[] {
  if (Array.isArray(value)) return value.flatMap(rawYieldParts);
  if (typeof value === "string") return [value];
  if (typeof value === "number") return Number.isFinite(value) ? [String(value)] : [];
  if (!value || typeof value !== "object") return [];

  const object = value as Record<string, unknown>;
  const name = typeof object.name === "string" ? cleanText(object.name) : "";
  const unitText = typeof object.unitText === "string" ? cleanText(object.unitText) : "";
  const values = rawYieldParts(object.value);
  const quantified = values.map((part) => appendUnitText(part, unitText));
  const minimum = rawYieldParts(object.minValue)[0];
  const maximum = rawYieldParts(object.maxValue)[0];
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
  const values: string[] = [];
  const pairedStarts = new Set<number>();
  const paired = /<([a-z][\w:-]*)\b([^>]*\bitemprop\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)[^>]*)>([\s\S]*?)<\/\1\s*>/giu;
  for (const match of html.matchAll(paired)) {
    if (!hasItemprop(match[2] ?? "", property)) continue;
    pairedStarts.add(match.index);
    const content = attributeValue(match[2] ?? "", "content");
    const text = content === undefined ? cleanHTML(match[3] ?? "") : cleanText(content);
    if (text) values.push(text);
  }

  const openingTags = /<([a-z][\w:-]*)\b([^>]*\bitemprop\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)[^>]*)\/?\s*>/giu;
  for (const match of html.matchAll(openingTags)) {
    if (pairedStarts.has(match.index) || !hasItemprop(match[2] ?? "", property)) continue;
    const content = attributeValue(match[2] ?? "", "content");
    if (content !== undefined) {
      const text = cleanText(content);
      if (text) values.push(text);
    }
  }
  return values;
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
  return cleanText(html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/giu, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/giu, " ")
    .replace(/<svg\b[^>]*>[\s\S]*?<\/svg>/giu, " ")
    .replace(/<(?:br|\/p|\/li|\/h[1-6]|\/section|\/div)>/giu, "\n")
    .replace(/<[^>]+>/gu, " "));
}

function cleanText(value: string): string {
  return decodeEntities(value)
    .replace(/[\t\r ]+/gu, " ")
    .replace(/ *\n */gu, "\n")
    .replace(/\n{3,}/gu, "\n\n")
    .trim();
}

function decodeEntities(value: string): string {
  const named: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " };
  return value.replace(/&(#x?[0-9a-f]+|[a-z]+);/giu, (_, entity: string) => {
    if (entity.startsWith("#x")) return String.fromCodePoint(Number.parseInt(entity.slice(2), 16));
    if (entity.startsWith("#")) return String.fromCodePoint(Number.parseInt(entity.slice(1), 10));
    return named[entity.toLowerCase()] ?? `&${entity};`;
  });
}
