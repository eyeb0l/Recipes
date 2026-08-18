import { APIError } from "../errors";
import type { ExtractionResult, NormalizedRecipeSource } from "../types";
import {
  extractionPrompt,
  imageDataURL,
  parseProviderJSON,
  providerSchema,
  requireProviderResponse,
  type RecipeExtractor
} from "./recipe-extractor";

export class GrokExtractor implements RecipeExtractor {
  readonly provider = "grok" as const;

  constructor(
    public readonly model: string,
    private readonly apiKey: string,
    private readonly fetcher: typeof fetch = fetch
  ) {
    if (!apiKey) throw new APIError(500, "provider_not_configured", "The configured Grok provider has no API key.");
  }

  async extract(source: NormalizedRecipeSource, requestID: string): Promise<ExtractionResult> {
    const content: Array<Record<string, unknown>> = [{ type: "text", text: extractionPrompt(source) }];
    for (const image of source.images) {
      content.push({ type: "image_url", image_url: { url: imageDataURL(image), detail: "high" } });
    }
    const response = await this.fetcher("https://api.x.ai/v1/chat/completions", {
      method: "POST",
      signal: AbortSignal.timeout(110_000),
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
        "X-Client-Request-ID": requestID
      },
      body: JSON.stringify({
        model: this.model,
        messages: [{ role: "user", content }],
        temperature: 0,
        stream: false,
        response_format: {
          type: "json_schema",
          json_schema: { name: "recipe_v1", strict: true, schema: providerSchema() }
        }
      })
    });
    const payload = await requireProviderResponse(response) as {
      choices?: Array<{ message?: { content?: string | Array<{ type?: string; text?: string }> } }>;
    };
    const contentValue = payload.choices?.[0]?.message?.content;
    const output = typeof contentValue === "string"
      ? contentValue
      : contentValue?.find((item) => item.type === "text")?.text;
    if (!output) throw new APIError(502, "invalid_model_output", "Grok returned no structured recipe.");
    return { recipe: parseProviderJSON(output), provider: this.provider, model: this.model };
  }
}
