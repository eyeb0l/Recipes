import type { RecipeExtractor } from "./recipe-extractor";
import { OpenAIExtractor } from "./openai-extractor";

/** The newest OpenAI model that balances vision accuracy, latency, and cost for recipe extraction. */
export const defaultOpenAIModel = "gpt-6.1-terra";

export function createExtractor(env: Env): RecipeExtractor {
  return new OpenAIExtractor(env.OPENAI_MODEL?.trim() || defaultOpenAIModel, env.OPENAI_API_KEY ?? "");
}

export type { RecipeExtractor } from "./recipe-extractor";
