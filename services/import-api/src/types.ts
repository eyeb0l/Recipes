export type ImportSourceType = "url" | "text" | "images";

export interface ImportMetadata {
  sourceType: ImportSourceType;
  url?: string | null;
  text?: string | null;
  recognizedText?: string | null;
  locale: string;
  preferredUnitSystem: "source" | "metric" | "imperial";
  idempotencyKey: string;
  /** RecipeV1 unit IDs the app can decode. Builds that predate the field omit it. */
  supportedUnits?: string[];
}

export interface NormalizedRecipeSource {
  sourceType: ImportSourceType;
  sourceURL?: string;
  sourceTitle?: string;
  ingredientsText?: string;
  instructionsText?: string;
  prose?: string;
  structuredYield?: { servings: number; label: string | null };
  pageText?: string;
  recognizedText?: string;
  images: Array<{ mimeType: string; bytes: ArrayBuffer }>;
  locale: string;
  preferredUnitSystem: string;
  /** The page's declared language, such as "en-GB", when a fetched page states one. */
  sourceLanguage?: string;
}

export interface ExtractionResult {
  recipe: unknown;
  provider: "openai";
  model: string;
}

export interface SessionClaims {
  sub: string;
  sid: string;
}

export interface SessionTokens {
  accessToken: string;
  refreshToken: string;
  accessExpiresAt: string;
  refreshExpiresAt: string;
}
