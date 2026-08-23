import { APIError } from "../errors";
import type { ExtractionResult, NormalizedRecipeSource } from "../types";
import {
  extractionPrompt,
  fetchProviderResponse,
  imageDataURL,
  parseProviderJSON,
  providerSchema,
  requireProviderResponse,
  sourceWarningInstructions,
  type RecipeExtractor
} from "./recipe-extractor";

export class OpenAIExtractor implements RecipeExtractor {
  readonly provider = "openai" as const;

  constructor(
    public readonly model: string,
    private readonly apiKey: string,
    private readonly fetcher: typeof fetch = fetch
  ) {
    if (!apiKey) throw new APIError(500, "provider_not_configured", "The configured OpenAI provider has no API key.");
  }

  async extract(source: NormalizedRecipeSource, requestID: string): Promise<ExtractionResult> {
    const content: Array<Record<string, unknown>> = [{ type: "input_text", text: extractionPrompt(source) }];
    for (const image of source.images) content.push({ type: "input_image", image_url: imageDataURL(image), detail: "high" });
    const response = await fetchProviderResponse(this.fetcher, "https://api.openai.com/v1/responses", {
      method: "POST",
      signal: AbortSignal.timeout(110_000),
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
        "X-Client-Request-ID": requestID
      },
      body: JSON.stringify({
        model: this.model,
        store: false,
        reasoning: { effort: "low" },
        instructions: sourceWarningInstructions,
        input: [{ role: "user", content }],
        text: { format: { type: "json_schema", name: "recipe_v1", strict: true, schema: providerSchema() } },
        max_output_tokens: 12_000
      })
    });
    const payload = await requireProviderResponse(response) as {
      output?: Array<{ content?: Array<{ type?: string; text?: string }> }>;
    };
    const output = payload.output?.flatMap((item) => item.content ?? []).find((item) => item.type === "output_text")?.text;
    if (!output) throw new APIError(502, "invalid_model_output", "OpenAI returned no structured recipe.");
    return { recipe: parseProviderJSON(output), provider: this.provider, model: this.model };
  }
}
