import { Hono } from "hono";
import { authenticate, issueSession, rotateSession, verifyAppleIdentityToken } from "./auth/session";
import { validateCanonicalRecipe } from "./canonical";
import { APIError, errorResponse } from "./errors";
import type { Fetcher, HostResolver } from "./extraction/public-fetch";
import { prepareImportRequest } from "./import-request";
import { createExtractor, type RecipeExtractor } from "./providers";
import { resolveRecipeServingCount } from "./serving-resolution";

type Variables = { requestID: string };
type AppBindings = { Bindings: Env; Variables: Variables };

export interface AppDependencies {
  verifyApple?: (token: string, audience: string) => Promise<string>;
  extractorFactory?: (env: Env) => RecipeExtractor;
  fetcher?: Fetcher;
  resolver?: HostResolver;
}

interface ImportResult {
  recipe: unknown;
  extraction: { provider: string; model: string; schemaVersion: number };
}

const inFlightImports = new Map<string, Promise<ImportResult>>();

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

    // Reject an exhausted allowance before fetching any source; the allowance is only spent below.
    await assertDailyQuotaAvailable(context.env, quotaKey);
    // Invalid sources and retries that join in-flight work never reach the provider, so they don't use the daily allowance.
    // Outbound page fetches have their own allowance, so failed URL imports can't fetch without limit.
    const prepared = await prepareImportRequest(
      context.req.raw,
      dependencies.fetcher,
      dependencies.resolver,
      () => consumeDailyFetchAllowance(context.env, quotaKey)
    );
    const dedupeKey = `${quotaKey}:${prepared.metadata.idempotencyKey}`;
    let work = inFlightImports.get(dedupeKey);
    if (!work) {
      const env = context.env;
      const requestID = context.get("requestID");
      work = consumeDailyQuota(env, quotaKey)
        .then(() => performImport(env, prepared, requestID, dependencies.extractorFactory));
      inFlightImports.set(dedupeKey, work);
      void work.finally(() => inFlightImports.delete(dedupeKey)).catch(() => undefined);
    }
    const result = await work;
    return context.json({ requestID: context.get("requestID"), ...result }, 200);
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
  recipe.provenance = prepared.provenance;
  validateCanonicalRecipe(recipe);
  return {
    recipe,
    extraction: { provider: result.provider, model: result.model, schemaVersion: 1 }
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

const dailyImportLimit = 20;
/** Public page fetches allowed per user per day, including fetches whose page turns out unusable. */
const dailyFetchLimit = 40;

function dailyQuotaKey(subjectHash: string): { day: string; key: string } {
  const day = new Date().toISOString().slice(0, 10);
  return { day, key: `quota:${day}:${subjectHash}` };
}

function quotaExceeded(): APIError {
  return new APIError(429, "quota_exceeded", "The daily private import allowance has been reached.");
}

async function assertDailyQuotaAvailable(env: Env, subjectHash: string): Promise<void> {
  const { key } = dailyQuotaKey(subjectHash);
  if (Number(await env.SESSIONS.get(key) ?? 0) >= dailyImportLimit) throw quotaExceeded();
}

async function consumeDailyFetchAllowance(env: Env, subjectHash: string): Promise<void> {
  const { day } = dailyQuotaKey(subjectHash);
  const key = `fetch-quota:${day}:${subjectHash}`;
  const current = Number(await env.SESSIONS.get(key) ?? 0);
  if (current >= dailyFetchLimit) {
    throw new APIError(429, "fetch_quota_exceeded", "Too many recipe links were tried today. Paste the recipe text or scan the page instead.");
  }
  await env.SESSIONS.put(key, String(current + 1), { expirationTtl: quotaTTLSeconds(day) });
}

function quotaTTLSeconds(day: string): number {
  return Math.max(60, Math.floor((Date.parse(`${day}T00:00:00.000Z`) + 2 * 86_400_000 - Date.now()) / 1_000));
}

async function consumeDailyQuota(env: Env, subjectHash: string): Promise<void> {
  const { day, key } = dailyQuotaKey(subjectHash);
  const current = Number(await env.SESSIONS.get(key) ?? 0);
  if (current >= dailyImportLimit) throw quotaExceeded();
  await env.SESSIONS.put(key, String(current + 1), { expirationTtl: quotaTTLSeconds(day) });
}

export default createApp();
