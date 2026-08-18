interface RateLimitBinding {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

interface Env {
  SESSIONS: KVNamespace;
  IMPORT_RATE_LIMITER: RateLimitBinding;
  APPLE_CLIENT_ID: string;
  SESSION_SIGNING_KEY: string;
  RECIPE_PROVIDER: "grok" | "openai";
  GROK_MODEL: string;
  OPENAI_MODEL: string;
  XAI_API_KEY?: string;
  OPENAI_API_KEY?: string;
}
