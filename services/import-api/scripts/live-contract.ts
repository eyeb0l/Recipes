import { validateCanonicalRecipe } from "../src/canonical";
import { GrokExtractor } from "../src/providers/grok-extractor";
import { OpenAIExtractor } from "../src/providers/openai-extractor";
import type { RecipeExtractor } from "../src/providers";

const provider = process.argv[2];
const requestedSourceType = process.argv[3];
if (requestedSourceType && requestedSourceType !== "text" && requestedSourceType !== "images") {
  throw new Error("Optional source filter must be text or images.");
}
let extractor: RecipeExtractor;
if (provider === "grok") {
  const key = process.env.XAI_API_KEY;
  if (!key) throw new Error("XAI_API_KEY is required; the Grok contract test will not substitute another model.");
  extractor = new GrokExtractor(process.env.GROK_MODEL ?? "grok-4.6", key);
} else if (provider === "openai") {
  const key = process.env.OPENAI_API_KEY;
  if (!key) throw new Error("OPENAI_API_KEY is required.");
  extractor = new OpenAIExtractor(process.env.OPENAI_MODEL ?? "gpt-5.6-luna", key);
} else {
  throw new Error("Usage: live-contract.ts grok|openai");
}

const recipeText = "Pancakes, serves 2. Ingredients: 100 g plain flour; 1 egg; 200 ml milk. Instructions: Whisk everything until smooth. Heat a frying pan over medium heat. Cook spoonfuls for 2 minutes per side until golden.";
// Keep the fixture above xAI's minimum image dimensions and total pixel count.
const blankPNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAACAAAAAgAQAAAABbAUdZAAAAD0lEQVQI12P4DwQMg5cAANrpf4GXVFCUAAAAAElFTkSuQmCC"), (character) => character.charCodeAt(0)).buffer;

const sources = [
  { sourceType: "text" as const, prose: recipeText, images: [], locale: "en_GB", preferredUnitSystem: "metric" },
  { sourceType: "images" as const, recognizedText: recipeText, images: [{ mimeType: "image/png", bytes: blankPNG }], locale: "en_GB", preferredUnitSystem: "metric" }
];

for (const source of sources.filter((candidate) => !requestedSourceType || candidate.sourceType === requestedSourceType)) {
  const result = await extractor.extract(source, crypto.randomUUID());
  validateCanonicalRecipe(result.recipe);
  const recipe = result.recipe as { yield: { servings: number }; stages: unknown[]; uncertainties: unknown[] };
  process.stdout.write(`${result.provider}/${result.model} ${source.sourceType}: valid RecipeV1 (${recipe.yield.servings} servings, ${recipe.stages.length} stages, ${recipe.uncertainties.length} uncertainties)\n`);
}
