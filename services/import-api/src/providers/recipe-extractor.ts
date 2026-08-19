import { canonicalRecipeSchema } from "../canonical";
import { APIError } from "../errors";
import type { ExtractionResult, NormalizedRecipeSource } from "../types";

export interface RecipeExtractor {
  readonly provider: "grok" | "openai";
  readonly model: string;
  extract(source: NormalizedRecipeSource, requestID: string): Promise<ExtractionResult>;
}

export async function fetchProviderResponse(
  fetcher: typeof fetch,
  input: RequestInfo | URL,
  init: RequestInit
): Promise<Response> {
  try {
    return await fetcher(input, init);
  } catch (error) {
    if (error instanceof APIError) throw error;
    const name = typeof error === "object" && error !== null && "name" in error
      ? String(error.name)
      : "";
    if (name === "TimeoutError" || name === "AbortError") {
      throw new APIError(504, "provider_timeout", "Recipe extraction took too long. Please try again.");
    }
    throw new APIError(503, "provider_unavailable", "The configured extraction provider could not be reached. Please try again.");
  }
}

export function providerSchema(): Record<string, unknown> {
  const { $schema: _, title: __, ...schema } = canonicalRecipeSchema;
  return schema;
}

export function extractionPrompt(source: NormalizedRecipeSource): string {
  const sourcePayload = source.ingredientsText || source.instructionsText
    ? [
        source.sourceTitle ? `Title: ${source.sourceTitle}` : "",
        source.ingredientsText ? `Ingredients:\n${source.ingredientsText}` : "",
        source.instructionsText ? `Instructions:\n${source.instructionsText}` : ""
      ].filter(Boolean).join("\n\n")
    : (source.prose ?? "");
  const ocr = source.recognizedText ? `\n\nOn-device OCR (may contain errors):\n${source.recognizedText.slice(0, 30_000)}` : "";
  return `Convert the supplied recipe into RecipeV1 canonical JSON.

Rules:
- Return only data allowed by the schema. Never return chart coordinates or presentation geometry.
- Preserve the source's meaning, ordering, state changes, divided ingredient uses, completion cues, heat, temperatures, and timing.
- Model parallel work using workstreams and dependency edges. A stage may depend on stages in multiple workstreams when they merge.
- Do not invent missing facts. Record every missing, ambiguous, or conflicting fact in uncertainties and link affected IDs.
- Every listed ingredient must be allocated to a stage or covered by an uncertainty.
- Use stable short string IDs and a directed acyclic stage graph.
- Quantities must remain decimal numbers or source text; never guess density-based mass/volume conversions.
- Set provenance.sourceType to ${source.sourceType}, provenance.url to ${source.sourceURL ?? "null"}, and schemaVersion to 1.
- The user's locale is ${source.locale}; their display-unit preference is ${source.preferredUnitSystem}, but preserve source quantities.

Source content:
${sourcePayload.slice(0, 45_000)}${ocr}`;
}

export function parseProviderJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new APIError(502, "invalid_model_output", "The provider returned malformed structured output.");
  }
}

export async function requireProviderResponse(response: Response): Promise<unknown> {
  if (!response.ok) {
    const retryable = response.status === 408 || response.status === 409 || response.status === 429 || response.status >= 500;
    throw new APIError(retryable ? 503 : 502, "provider_error", "The configured extraction provider could not complete the request.");
  }
  try { return await response.json(); } catch {
    throw new APIError(502, "provider_error", "The configured extraction provider returned an unreadable response.");
  }
}

export function imageDataURL(image: { mimeType: string; bytes: ArrayBuffer }): string {
  const bytes = new Uint8Array(image.bytes);
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 16_384) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + 16_384, bytes.length)));
  }
  return `data:${image.mimeType};base64,${btoa(binary)}`;
}
