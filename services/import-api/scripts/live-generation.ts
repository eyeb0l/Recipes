import { validateCanonicalRecipe } from "../src/canonical";
import { defaultOpenAIModel } from "../src/providers";
import { OpenAIGenerator } from "../src/providers/openai-generator";
import type { GenerationBrief } from "../src/types";

// Writes one recipe with web search, then revises it, and prints only counts and timings.
const key = process.env.OPENAI_API_KEY;
if (!key) throw new Error("OPENAI_API_KEY is required; the contract test never substitutes another model.");
const webSearch = process.env.OPENAI_WEB_SEARCH?.trim().toLowerCase() !== "off";
const generator = new OpenAIGenerator(process.env.OPENAI_MODEL?.trim() || defaultOpenAIModel, key, webSearch);

const brief: GenerationBrief = {
  request: "A traditional Irish soda bread, baked in a home oven, for 8 slices.",
  locale: "en_GB",
  preferredUnitSystem: "metric"
};

async function run(label: string, value: GenerationBrief): Promise<Record<string, unknown>> {
  const started = Date.now();
  const result = await generator.generate(value, crypto.randomUUID());
  const recipe = result.recipe as Record<string, any>;
  recipe.provenance = { sourceType: "generated", url: null, title: null, cleanedText: null, importedAt: new Date().toISOString() };
  validateCanonicalRecipe(recipe);
  const seconds = ((Date.now() - started) / 1_000).toFixed(1);
  process.stdout.write(`${result.provider}/${result.model} ${label}: valid RecipeV1 in ${seconds}s (web search ${result.webSearch ? "on" : "off"}, ${result.sources.length} sources, ${recipe.yield.servings} servings, ${recipe.ingredients.length} ingredients, ${recipe.stages.length} stages, ${recipe.uncertainties.length} uncertainties)\n`);
  return result.recipe as Record<string, unknown>;
}

const draft = await run("generate", brief);
const feedback = "Make it with wholemeal flour, and add a handful of oats on top.";
const revised = await run("revise", { ...brief, revision: { recipe: draft, feedback, earlierFeedback: [], sources: [] } });
const names = (recipe: Record<string, any>) => (recipe.ingredients as Array<{ name: string }>).map((item) => item.name.toLowerCase()).join(", ");
process.stdout.write(`revision mentions wholemeal: ${/wholemeal|whole ?wheat/u.test(names(revised))}; oats: ${/oat/u.test(names(revised))}\n`);
