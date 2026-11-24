import type { RecipeExtractor } from "./recipe-extractor";
import type { RecipeGenerator } from "./recipe-generator";
import { OpenAIExtractor } from "./openai-extractor";
import { OpenAIGenerator } from "./openai-generator";

/** The newest OpenAI model that balances vision accuracy, latency, and cost for recipe extraction. */
export const defaultOpenAIModel = "gpt-6.1-terra";

export function createExtractor(env: Env): RecipeExtractor {
  return new OpenAIExtractor(env.OPENAI_MODEL?.trim() || defaultOpenAIModel, env.OPENAI_API_KEY ?? "");
}

/** Uses the same model as imports. Web search is on unless `OPENAI_WEB_SEARCH` is "off". */
export function createGenerator(env: Env): RecipeGenerator {
  return new OpenAIGenerator(
    env.OPENAI_MODEL?.trim() || defaultOpenAIModel,
    env.OPENAI_API_KEY ?? "",
    env.OPENAI_WEB_SEARCH?.trim().toLowerCase() !== "off"
  );
}

export type { RecipeExtractor } from "./recipe-extractor";
export type { RecipeGenerator } from "./recipe-generator";
