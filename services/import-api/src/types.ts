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

/** What the cook asked for, and for a revision, the draft and what to change about it. */
export interface GenerationBrief {
  request: string;
  locale: string;
  preferredUnitSystem: "source" | "metric" | "imperial";
  revision?: {
    recipe: Record<string, unknown>;
    feedback: string;
    /** Changes asked for in earlier revisions, oldest first, which should still hold. */
    earlierFeedback: string[];
    /** Sources found for earlier drafts, which still shaped this one. */
    sources: GenerationSource[];
  };
}

export interface GenerationSource {
  title: string | null;
  url: string;
}

export interface GenerationResult {
  recipe: unknown;
  provider: "openai";
  model: string;
  webSearch: boolean;
  /** Web pages the model cited, without duplicates. */
  sources: GenerationSource[];
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
