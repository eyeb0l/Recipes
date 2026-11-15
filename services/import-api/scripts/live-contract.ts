import { validateCanonicalRecipe } from "../src/canonical";
import { defaultOpenAIModel } from "../src/providers";
import { OpenAIExtractor } from "../src/providers/openai-extractor";

const requestedSourceType = process.argv[2];
if (requestedSourceType && requestedSourceType !== "text" && requestedSourceType !== "images") {
  throw new Error("Optional source filter must be text or images.");
}
const key = process.env.OPENAI_API_KEY;
if (!key) throw new Error("OPENAI_API_KEY is required; the contract test never substitutes another model.");
const extractor = new OpenAIExtractor(process.env.OPENAI_MODEL?.trim() || defaultOpenAIModel, key);

const recipeText = "Pancakes, serves 2. Ingredients: 100 g plain flour; 1 egg; 200 ml milk. Instructions: Whisk everything until smooth. Heat a frying pan over medium heat. Cook spoonfuls for 2 minutes per side until golden.";
// A small, valid PNG keeps the image path exercised without sending real cookbook content.
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
