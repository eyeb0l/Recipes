import { APIError } from "../errors";

export interface ExtractedPageRecipe {
  title?: string;
  ingredients: string[];
  instructions: string[];
  cleanedText: string;
  method: "json-ld" | "microdata" | "cleaned-prose";
}

export function extractRecipeFromHTML(html: string): ExtractedPageRecipe {
  const jsonLD = extractJSONLD(html);
  if (jsonLD) return jsonLD;
  const microdata = extractMicrodata(html);
  if (microdata) return microdata;
  const cleanedText = cleanHTML(html);
  if (cleanedText.length < 80) {
    throw new APIError(422, "source_blocked", "The site did not expose readable recipe content. Paste its recipe text or scan the page instead.");
  }
  return { ingredients: [], instructions: [], cleanedText, method: "cleaned-prose" };
}

function extractJSONLD(html: string): ExtractedPageRecipe | undefined {
  const scripts = html.matchAll(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/giu);
  for (const match of scripts) {
    try {
      const parsed: unknown = JSON.parse(decodeEntities(match[1] ?? "").trim());
      const recipe = findRecipe(parsed);
      if (!recipe) continue;
      const ingredients = stringArray(recipe.recipeIngredient);
      const instructions = instructionArray(recipe.recipeInstructions);
      if (ingredients.length === 0 && instructions.length === 0) continue;
      const title = typeof recipe.name === "string" ? recipe.name.trim() : undefined;
      const cleanedText = [title, "Ingredients", ...ingredients, "Instructions", ...instructions].filter(Boolean).join("\n");
      return { title, ingredients, instructions, cleanedText, method: "json-ld" };
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

function extractMicrodata(html: string): ExtractedPageRecipe | undefined {
  if (!/itemtype=["'][^"']*schema\.org\/Recipe/iu.test(html)) return undefined;
  const ingredients = [...html.matchAll(/<[^>]+itemprop=["'](?:recipeIngredient|ingredients)["'][^>]*>([\s\S]*?)<\/[^>]+>/giu)]
    .map((match) => cleanHTML(match[1] ?? "")).filter(Boolean);
  const instructions = [...html.matchAll(/<[^>]+itemprop=["']recipeInstructions["'][^>]*>([\s\S]*?)<\/[^>]+>/giu)]
    .map((match) => cleanHTML(match[1] ?? "")).filter(Boolean);
  if (ingredients.length === 0 && instructions.length === 0) return undefined;
  const name = html.match(/<[^>]+itemprop=["']name["'][^>]*>([\s\S]*?)<\/[^>]+>/iu);
  const title = name ? cleanHTML(name[1] ?? "") : undefined;
  return {
    title,
    ingredients,
    instructions,
    cleanedText: [title, "Ingredients", ...ingredients, "Instructions", ...instructions].filter(Boolean).join("\n"),
    method: "microdata"
  };
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
