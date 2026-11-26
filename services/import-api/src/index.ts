import { Hono } from "hono";
import { authenticate, issueSession, rotateSession, verifyAppleIdentityToken } from "./auth/session";
import { validateCanonicalRecipe } from "./canonical";
import { APIError, errorResponse } from "./errors";
import type { Fetcher, HostResolver } from "./extraction/public-fetch";
import { prepareGenerationRequest } from "./generation-request";
import { prepareImportRequest } from "./import-request";
import { createExtractor, createGenerator, type RecipeExtractor, type RecipeGenerator } from "./providers";
import { cleanSources, generationProvenanceText } from "./providers/recipe-generator";
import { consumeDailyAllowance } from "./quota";
import { resolveRecipeServingCount } from "./serving-resolution";
import { adaptRecipeUnitsForClient, reconcileSystemDependentUnits } from "./unit-resolution";

type Variables = { requestID: string };
type AppBindings = { Bindings: Env; Variables: Variables };

export interface AppDependencies {
  verifyApple?: (token: string, audience: string) => Promise<string>;
  extractorFactory?: (env: Env) => RecipeExtractor;
  generatorFactory?: (env: Env) => RecipeGenerator;
  fetcher?: Fetcher;
  resolver?: HostResolver;
}

interface ImportResult {
  recipe: unknown;
  extraction: { provider: string; model: string; schemaVersion: number };
}

interface GenerationResponse {
  recipe: unknown;
  generation: { provider: string; model: string; schemaVersion: number; webSearch: boolean };
  sources: Array<{ title: string | null; url: string }>;
}

const inFlightImports = new Map<string, Promise<ImportResult>>();
const inFlightGenerations = new Map<string, Promise<GenerationResponse>>();

export function createApp(dependencies: AppDependencies = {}) {
  const app = new Hono<AppBindings>();

  app.use("*", async (context, next) => {
    const incoming = context.req.header("X-Request-ID")?.trim();
    const requestID = incoming && /^[a-zA-Z0-9._-]{1,128}$/u.test(incoming) ? incoming : crypto.randomUUID();
    context.set("requestID", requestID);
    await next();
    context.header("Cache-Control", "no-store");
    context.header("X-Request-ID", requestID);
    context.header("Referrer-Policy", "no-referrer");
    context.header("X-Content-Type-Options", "nosniff");
  });

  app.get("/health", (context) => context.json({ status: "ok", schemaVersion: 1 }));

  app.post("/v1/session/apple", async (context) => {
    const body = await limitedJSON(context.req.raw, 16_000) as { identityToken?: string; authorizationCode?: string };
    if (!body.identityToken || body.identityToken.length > 16_000) throw new APIError(400, "missing_apple_token", "An Apple identity token is required.");
    const subject = await (dependencies.verifyApple ?? verifyAppleIdentityToken)(body.identityToken, context.env.APPLE_CLIENT_ID);
    return context.json(await issueSession(context.env, subject));
  });

  app.post("/v1/session/refresh", async (context) => {
    const body = await limitedJSON(context.req.raw, 2_000) as { refreshToken?: string };
    return context.json(await rotateSession(context.env, body.refreshToken ?? ""));
  });

  app.post("/v1/recipe-imports", async (context) => {
    const claims = await authenticate(context.req.raw, context.env);
    const quotaKey = await subjectDigest(claims.sub);
    const quota = await context.env.IMPORT_RATE_LIMITER.limit({ key: quotaKey });
    if (!quota.success) throw new APIError(429, "rate_limited", "Too many imports were started at once. Try again shortly.");

    // Invalid sources and retries that join in-flight work never reach the provider, so they don't use the daily allowance.
    // New URL imports are checked against the allowance before fetching, and outbound page fetches have
    // their own daily cap, so failed links can't fetch without limit.
    const prepared = await prepareImportRequest(
      context.req.raw,
      dependencies.fetcher,
      dependencies.resolver,
      async (metadata) => {
        // A retry joining in-flight work was already admitted, but every outbound fetch still counts.
        const joining = inFlightImports.has(`${quotaKey}:${metadata.idempotencyKey}`);
        await consumeDailyAllowance(context.env, quotaKey, joining ? "retry-fetch" : "fetch");
      }
    );
    const dedupeKey = `${quotaKey}:${prepared.metadata.idempotencyKey}`;
    let work = inFlightImports.get(dedupeKey);
    if (!work) {
      const env = context.env;
      const requestID = context.get("requestID");
      work = consumeDailyAllowance(env, quotaKey, "provider")
        .then(() => performImport(env, prepared, requestID, dependencies.extractorFactory));
      inFlightImports.set(dedupeKey, work);
      void work.finally(() => inFlightImports.delete(dedupeKey)).catch(() => undefined);
    }
    const result = await work;
    // A retry can join work started by another request, so each response adapts its own copy.
    const recipe = structuredClone(result.recipe) as Record<string, unknown>;
    adaptRecipeUnitsForClient(recipe, prepared.metadata.supportedUnits);
    return context.json({ requestID: context.get("requestID"), ...result, recipe }, 200);
  });

  app.post("/v1/recipe-generations", async (context) => {
    const claims = await authenticate(context.req.raw, context.env);
    const quotaKey = await subjectDigest(claims.sub);
    const quota = await context.env.IMPORT_RATE_LIMITER.limit({ key: quotaKey });
    if (!quota.success) throw new APIError(429, "rate_limited", "Too many recipes were started at once. Try again shortly.");

    // Writing or revising a recipe shares the daily allowance with imports. Invalid requests and
    // retries that join in-flight work never reach the provider, so they don't use it.
    const prepared = await prepareGenerationRequest(context.req.raw);
    const dedupeKey = `${quotaKey}:${prepared.idempotencyKey}`;
    let work = inFlightGenerations.get(dedupeKey);
    if (!work) {
      const env = context.env;
      const requestID = context.get("requestID");
      work = consumeDailyAllowance(env, quotaKey, "provider")
        .then(() => performGeneration(env, prepared.brief, requestID, dependencies.generatorFactory));
      inFlightGenerations.set(dedupeKey, work);
      void work.finally(() => inFlightGenerations.delete(dedupeKey)).catch(() => undefined);
    }
    const result = await work;
    const recipe = structuredClone(result.recipe) as Record<string, unknown>;
    adaptRecipeUnitsForClient(recipe, prepared.supportedUnits);
    return context.json({ requestID: context.get("requestID"), ...result, recipe }, 200);
  });

  app.notFound((context) => context.json({ error: { code: "not_found", message: "Route not found." }, requestID: context.get("requestID") }, 404));
  app.onError((error, context) => errorResponse(error, context.get("requestID") || crypto.randomUUID()));
  return app;
}

async function performImport(
  env: Env,
  prepared: Awaited<ReturnType<typeof prepareImportRequest>>,
  requestID: string,
  factory: AppDependencies["extractorFactory"]
): Promise<ImportResult> {
  const extractor = (factory ?? createExtractor)(env);
  const result = await extractor.extract(prepared.source, requestID);
  if (!result.recipe || typeof result.recipe !== "object" || Array.isArray(result.recipe)) {
    throw new APIError(502, "invalid_model_output", "The provider returned an invalid canonical recipe.");
  }
  const recipe = structuredClone(result.recipe) as Record<string, unknown>;
  resolveRecipeServingCount(recipe, prepared.source);
  reconcileSystemDependentUnits(recipe);
  recipe.provenance = prepared.provenance;
  validateCanonicalRecipe(recipe);
  return {
    recipe,
    extraction: { provider: result.provider, model: result.model, schemaVersion: 1 }
  };
}

async function performGeneration(
  env: Env,
  brief: Parameters<RecipeGenerator["generate"]>[0],
  requestID: string,
  factory: AppDependencies["generatorFactory"]
): Promise<GenerationResponse> {
  const generator = (factory ?? createGenerator)(env);
  const result = await generator.generate(brief, requestID);
  if (!result.recipe || typeof result.recipe !== "object" || Array.isArray(result.recipe)) {
    throw new APIError(502, "invalid_model_output", "The provider returned an invalid canonical recipe.");
  }
  const recipe = structuredClone(result.recipe) as Record<string, unknown>;
  // The app saves recipes by ID, so a new recipe must never reuse one already in the library,
  // and a revision must keep its draft's ID.
  recipe.id = brief.revision ? brief.revision.recipe.id : `generated-${crypto.randomUUID()}`;
  reconcileSystemDependentUnits(recipe);
  // A revision often doesn't search again, but the pages found for earlier drafts still shaped it.
  const sources = cleanSources([...result.sources, ...brief.revision?.sources ?? []]);
  recipe.provenance = {
    sourceType: "generated",
    url: null,
    title: null,
    cleanedText: generationProvenanceText(brief, sources),
    importedAt: new Date().toISOString()
  };
  validateCanonicalRecipe(recipe);
  return {
    recipe,
    generation: { provider: result.provider, model: result.model, schemaVersion: 1, webSearch: result.webSearch },
    sources
  };
}

async function limitedJSON(request: Request, maximum: number): Promise<unknown> {
  const declared = Number(request.headers.get("Content-Length") ?? 0);
  if (declared > maximum) throw new APIError(413, "request_too_large", "The request is too large.");
  const text = await request.text();
  if (!text || text.length > maximum) throw new APIError(400, "invalid_json", "The JSON request is empty or too large.");
  try { return JSON.parse(text); } catch { throw new APIError(400, "invalid_json", "The request body is not valid JSON."); }
}

async function subjectDigest(subject: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(subject));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export default createApp();
