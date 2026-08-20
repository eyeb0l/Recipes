import type { RecipeExtractor } from "./recipe-extractor";
import { GrokExtractor } from "./grok-extractor";
import { OpenAIExtractor } from "./openai-extractor";

export function createExtractor(env: Env): RecipeExtractor {
  if (env.RECIPE_PROVIDER === "grok") {
    return new GrokExtractor(env.GROK_MODEL || "grok-4.6", env.XAI_API_KEY ?? "");
  }
  return new OpenAIExtractor(env.OPENAI_MODEL || "gpt-5.6-luna", env.OPENAI_API_KEY ?? "");
}

export type { RecipeExtractor } from "./recipe-extractor";
