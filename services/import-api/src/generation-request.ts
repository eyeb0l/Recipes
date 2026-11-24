import { APIError } from "./errors";
import { cleanSources, maximumGenerationSources } from "./providers/recipe-generator";
import type { GenerationBrief } from "./types";

const maxJSONBytes = 300_000;
const maxRecipeJSONLength = 200_000;
export const minimumRequestLength = 3;
export const maximumRequestLength = 2_000;
export const maximumFeedbackLength = 2_000;
export const maximumEarlierFeedback = 10;

export interface GenerationMetadata {
  request?: unknown;
  locale?: unknown;
  preferredUnitSystem?: unknown;
  idempotencyKey?: unknown;
  supportedUnits?: unknown;
  revision?: unknown;
}

export interface PreparedGeneration {
  idempotencyKey: string;
  supportedUnits?: string[];
  brief: GenerationBrief;
}

/** Reads and validates a generation or revision request. Nothing here calls the provider. */
export async function prepareGenerationRequest(request: Request): Promise<PreparedGeneration> {
  if (!(request.headers.get("Content-Type") ?? "").startsWith("application/json")) {
    throw new APIError(415, "unsupported_media_type", "Use application/json.");
  }
  if (Number(request.headers.get("Content-Length") ?? 0) > maxJSONBytes) {
    throw new APIError(413, "request_too_large", "The request is too large.");
  }
  const raw = await request.text();
  if (raw.length === 0 || raw.length > maxJSONBytes) throw new APIError(413, "invalid_metadata", "The request is empty or too large.");
  let value: GenerationMetadata;
  try { value = JSON.parse(raw) as GenerationMetadata; } catch {
    throw new APIError(400, "invalid_metadata", "The request is not valid JSON.");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new APIError(400, "invalid_metadata", "The request is not valid JSON.");

  if (typeof value.locale !== "string" || !value.locale || value.locale.length > 64
    || typeof value.preferredUnitSystem !== "string" || !new Set(["source", "metric", "imperial"]).has(value.preferredUnitSystem)) {
    throw new APIError(400, "invalid_metadata", "Locale or unit preference is invalid.");
  }
  if (typeof value.idempotencyKey !== "string" || !value.idempotencyKey || value.idempotencyKey.length > 128) {
    throw new APIError(400, "invalid_idempotency_key", "An idempotency key is required.");
  }
  const supportedUnits = value.supportedUnits;
  if (supportedUnits !== undefined && (
    !Array.isArray(supportedUnits)
    || supportedUnits.length > 100
    || supportedUnits.some((unit) => typeof unit !== "string" || unit.length === 0 || unit.length > 64)
  )) {
    throw new APIError(400, "invalid_metadata", "The supported units are invalid.");
  }

  const wish = typeof value.request === "string" ? value.request.trim() : "";
  if (wish.length < minimumRequestLength || wish.length > maximumRequestLength) {
    throw new APIError(400, "invalid_request", `Describe the recipe you'd like in ${minimumRequestLength} to ${maximumRequestLength.toLocaleString("en-GB")} characters.`);
  }

  return {
    idempotencyKey: value.idempotencyKey,
    supportedUnits: supportedUnits as string[] | undefined,
    brief: {
      request: wish,
      locale: value.locale,
      preferredUnitSystem: value.preferredUnitSystem as GenerationBrief["preferredUnitSystem"],
      revision: value.revision === undefined || value.revision === null ? undefined : parseRevision(value.revision)
    }
  };
}

function parseRevision(value: unknown): NonNullable<GenerationBrief["revision"]> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalidRevision();
  const revision = value as { recipe?: unknown; feedback?: unknown; earlierFeedback?: unknown; sources?: unknown };
  const feedback = typeof revision.feedback === "string" ? revision.feedback.trim() : "";
  if (!feedback || feedback.length > maximumFeedbackLength) {
    throw new APIError(400, "invalid_feedback", `Say what to change in 1 to ${maximumFeedbackLength.toLocaleString("en-GB")} characters.`);
  }
  const earlier = revision.earlierFeedback ?? [];
  if (!Array.isArray(earlier) || earlier.length > maximumEarlierFeedback
    || earlier.some((item) => typeof item !== "string" || item.trim().length === 0 || item.length > maximumFeedbackLength)) {
    throw invalidRevision();
  }
  const sources = revision.sources ?? [];
  if (!Array.isArray(sources) || sources.length > maximumGenerationSources
    || sources.some((item) => !item || typeof item !== "object" || Array.isArray(item))) {
    throw invalidRevision();
  }
  // The draft is context for the model, which returns a whole new recipe that is validated in full,
  // so only what the server itself reads is checked here.
  const recipe = revision.recipe;
  if (!recipe || typeof recipe !== "object" || Array.isArray(recipe)) throw invalidRevision();
  const { id, title } = recipe as { id?: unknown; title?: unknown };
  if (typeof id !== "string" || !id.trim() || id.length > 128 || typeof title !== "string" || !title.trim()) throw invalidRevision();
  if (JSON.stringify(recipe).length > maxRecipeJSONLength) throw new APIError(413, "invalid_revision", "The recipe to revise is too large.");
  return {
    recipe: recipe as Record<string, unknown>,
    feedback,
    earlierFeedback: (earlier as string[]).map((item) => item.trim()),
    sources: cleanSources(sources as Array<{ url?: unknown; title?: unknown }>)
  };
}

function invalidRevision(): APIError {
  return new APIError(400, "invalid_revision", "The recipe to revise is missing or invalid.");
}
