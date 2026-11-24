import { APIError } from "../errors";
import type { GenerationBrief, GenerationResult } from "../types";
import { fetchProviderResponse, parseProviderJSON, providerSchema, requireProviderResponse } from "./recipe-extractor";
import { cleanSources, generationInstructions, generationPrompt, type RecipeGenerator } from "./recipe-generator";

/** Reasoning and web search share this budget with the recipe itself. */
export const openAIGenerationMaxOutputTokens = 24_000;
/** Searching the web adds round trips, so generation gets longer than extraction. */
export const openAIGenerationTimeoutMs = 150_000;

interface Annotation { type?: string; url?: string; title?: string }

interface ResponsesPayload {
  status?: string;
  incomplete_details?: { reason?: string } | null;
  output?: Array<{
    type?: string;
    action?: { sources?: Array<{ url?: string; title?: string }> };
    content?: Array<{ type?: string; text?: string; refusal?: string; annotations?: Annotation[] }>;
  }>;
}

export class OpenAIGenerator implements RecipeGenerator {
  readonly provider = "openai" as const;

  constructor(
    public readonly model: string,
    private readonly apiKey: string,
    public readonly webSearch: boolean = true,
    private readonly fetcher: typeof fetch = fetch
  ) {
    if (!apiKey) throw new APIError(500, "provider_not_configured", "The configured OpenAI provider has no API key.");
  }

  async generate(brief: GenerationBrief, requestID: string): Promise<GenerationResult> {
    let response: Response;
    try {
      response = await fetchProviderResponse(this.fetcher, "https://api.openai.com/v1/responses", {
        method: "POST",
        signal: AbortSignal.timeout(openAIGenerationTimeoutMs),
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
          "X-Client-Request-ID": requestID
        },
        body: JSON.stringify({
          model: this.model,
          store: false,
          reasoning: { effort: "low" },
          instructions: generationInstructions,
          input: [{ role: "user", content: [{ type: "input_text", text: generationPrompt(brief) }] }],
          ...(this.webSearch ? {
            tools: [webSearchTool(brief.locale)],
            include: ["web_search_call.action.sources"]
          } : {}),
          text: { format: { type: "json_schema", name: "recipe_v1", strict: true, schema: providerSchema() } },
          max_output_tokens: openAIGenerationMaxOutputTokens
        })
      });
    } catch (error) {
      if (error instanceof APIError && error.code === "provider_timeout") {
        throw new APIError(504, "provider_timeout", "Writing the recipe took too long. Please try again.");
      }
      throw error;
    }
    const payload = await requireProviderResponse(response) as ResponsesPayload;
    const output = payload.output ?? [];
    const content = output.flatMap((item) => item.type === "message" || item.type === undefined ? item.content ?? [] : []);

    if (content.some((item) => item.type === "refusal")) {
      throw new APIError(422, "request_refused", "This request couldn't be turned into a recipe. Describe something to eat or drink, then try again.");
    }
    if (payload.status === "incomplete") {
      throw new APIError(
        502,
        "incomplete_model_output",
        payload.incomplete_details?.reason === "max_output_tokens"
          ? "This recipe came out too long. Ask for something simpler, or fewer components."
          : "Writing the recipe stopped early. Please try again."
      );
    }
    const text = content.filter((item) => item.type === "output_text").at(-1)?.text;
    if (!text) throw new APIError(502, "invalid_model_output", "OpenAI returned no structured recipe.");

    // Pages the answer cites come first, then the rest of what the searches read.
    const cited = content.flatMap((item) => item.annotations ?? []).filter((annotation) => annotation.type === "url_citation");
    const consulted = output.filter((item) => item.type === "web_search_call").flatMap((item) => item.action?.sources ?? []);
    return {
      recipe: parseProviderJSON(text),
      provider: this.provider,
      model: this.model,
      webSearch: this.webSearch,
      sources: cleanSources([...cited, ...consulted])
    };
  }
}

/** Search near the cook, so it finds their ingredient names and measures, without sending anything more precise than a country. */
export function webSearchTool(locale: string): Record<string, unknown> {
  const country = /^[a-z]{2,3}[_-]([A-Z]{2})\b/u.exec(locale)?.[1];
  return country
    ? { type: "web_search", user_location: { type: "approximate", country } }
    : { type: "web_search" };
}
