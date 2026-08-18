import { APIError } from "./errors";
import { extractRecipeFromHTML } from "./extraction/html-recipe";
import { fetchPublicRecipe, type Fetcher, type HostResolver } from "./extraction/public-fetch";
import type { ImportMetadata, NormalizedRecipeSource } from "./types";

const maxJSONBytes = 300_000;
const maxImageBytes = 8_000_000;
const maxTotalImageBytes = 24_000_000;
const allowedImages = new Set(["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"]);

export interface PreparedImport {
  metadata: ImportMetadata;
  source: NormalizedRecipeSource;
  provenance: { sourceType: string; url: string | null; title: string | null; cleanedText: string; importedAt: string };
}

export async function prepareImportRequest(
  request: Request,
  fetcher: Fetcher = fetch,
  resolver?: HostResolver
): Promise<PreparedImport> {
  const declaredLength = Number(request.headers.get("Content-Length") ?? 0);
  if (declaredLength > maxTotalImageBytes + maxJSONBytes) throw new APIError(413, "request_too_large", "The import request is too large.");
  const contentType = request.headers.get("Content-Type") ?? "";
  let metadata: ImportMetadata;
  let images: NormalizedRecipeSource["images"] = [];

  if (contentType.startsWith("multipart/form-data")) {
    const form = await request.formData();
    const metadataPart = form.get("metadata");
    if (typeof metadataPart !== "string" || metadataPart.length > maxJSONBytes) throw new APIError(400, "invalid_metadata", "Image import metadata is missing or invalid.");
    metadata = parseMetadata(metadataPart);
    const files = form.getAll("images");
    if (files.length < 1 || files.length > 4 || files.some((value) => !(value instanceof File))) {
      throw new APIError(400, "invalid_images", "Attach between one and four cookbook images.");
    }
    let total = 0;
    images = await Promise.all(files.map(async (value) => {
      const file = value as File;
      total += file.size;
      if (!allowedImages.has(file.type) || file.size === 0 || file.size > maxImageBytes || total > maxTotalImageBytes) {
        throw new APIError(413, "invalid_images", "Each image must be a supported format under 8 MB, with no more than 24 MB total.");
      }
      return { mimeType: file.type, bytes: await file.arrayBuffer() };
    }));
  } else if (contentType.startsWith("application/json")) {
    const raw = await request.text();
    if (raw.length === 0 || raw.length > maxJSONBytes) throw new APIError(413, "invalid_metadata", "The import request is empty or too large.");
    metadata = parseMetadata(raw);
  } else {
    throw new APIError(415, "unsupported_media_type", "Use application/json or multipart/form-data.");
  }

  validateMetadata(metadata, images.length);
  const importedAt = new Date().toISOString();
  if (metadata.sourceType === "url") {
    const page = await fetchPublicRecipe(metadata.url!, fetcher, resolver ?? undefined);
    const extracted = extractRecipeFromHTML(page.contentType.includes("json") ? `<script type="application/ld+json">${page.body}</script>` : page.body);
    return {
      metadata,
      source: {
        sourceType: "url",
        sourceURL: page.finalURL,
        sourceTitle: extracted.title,
        ingredientsText: extracted.ingredients.join("\n"),
        instructionsText: extracted.instructions.join("\n"),
        prose: extracted.ingredients.length || extracted.instructions.length ? undefined : extracted.cleanedText,
        images: [],
        locale: metadata.locale,
        preferredUnitSystem: metadata.preferredUnitSystem
      },
      provenance: { sourceType: "url", url: page.finalURL, title: extracted.title ?? null, cleanedText: extracted.cleanedText, importedAt }
    };
  }

  const cleanedText = metadata.sourceType === "text" ? metadata.text!.trim() : (metadata.recognizedText ?? "").trim();
  return {
    metadata,
    source: {
      sourceType: metadata.sourceType,
      prose: metadata.sourceType === "text" ? cleanedText : undefined,
      recognizedText: metadata.recognizedText?.trim(),
      images,
      locale: metadata.locale,
      preferredUnitSystem: metadata.preferredUnitSystem
    },
    provenance: { sourceType: metadata.sourceType, url: null, title: null, cleanedText, importedAt }
  };
}

function parseMetadata(raw: string): ImportMetadata {
  try { return JSON.parse(raw) as ImportMetadata; } catch {
    throw new APIError(400, "invalid_metadata", "The import metadata is not valid JSON.");
  }
}

function validateMetadata(value: ImportMetadata, imageCount: number): void {
  if (!value || !new Set(["url", "text", "images"]).has(value.sourceType)) throw new APIError(400, "invalid_source", "Choose exactly one import source.");
  if (!value.locale || value.locale.length > 64 || !new Set(["source", "metric", "imperial"]).has(value.preferredUnitSystem)) {
    throw new APIError(400, "invalid_metadata", "Locale or unit preference is invalid.");
  }
  if (!value.idempotencyKey || value.idempotencyKey.length > 128) throw new APIError(400, "invalid_idempotency_key", "An idempotency key is required.");
  const hasURL = typeof value.url === "string" && value.url.length > 0;
  const hasText = typeof value.text === "string" && value.text.trim().length > 0;
  if (value.sourceType === "url" && (!hasURL || hasText || imageCount > 0)) throw new APIError(400, "invalid_source", "URL imports must contain only one URL.");
  if (value.sourceType === "text" && (!hasText || hasURL || imageCount > 0)) throw new APIError(400, "invalid_source", "Text imports must contain only pasted recipe text.");
  if (value.sourceType === "images" && (hasURL || hasText || imageCount < 1)) throw new APIError(400, "invalid_source", "Image imports must contain one to four images.");
  if (hasURL && value.url!.length > 2_048) throw new APIError(400, "invalid_url", "The recipe URL is too long.");
  if (hasText && (value.text!.trim().length < 40 || value.text!.length > 200_000)) throw new APIError(400, "invalid_text", "Paste between 40 and 200,000 characters of recipe text.");
  if (value.recognizedText && value.recognizedText.length > 100_000) throw new APIError(400, "invalid_ocr", "The OCR text is too large.");
}
