import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/index";
import type { RecipeExtractor } from "../src/providers";
import { testEnv, validRecipe } from "./fixtures";

const pastedRecipe = "Mix 100 g flour with enough water to make a smooth batter. Cook in a hot pan until set on both sides.";

async function accessToken(app: ReturnType<typeof createApp>, env: Env): Promise<string> {
  const response = await app.request("/v1/session/apple", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ identityToken: "signed-apple-token" })
  }, env);
  expect(response.status).toBe(200);
  return (await response.json() as { accessToken: string }).accessToken;
}

function importRequest(token: string, idempotencyKey = "import-1"): RequestInit {
  return {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}`, "X-Request-ID": "safe-request-id" },
    body: JSON.stringify({
      sourceType: "text",
      text: pastedRecipe,
      locale: "en_GB",
      preferredUnitSystem: "metric",
      idempotencyKey
    })
  };
}

describe("import API", () => {
  it("authenticates, extracts, validates, and returns provider metadata", async () => {
    const env = testEnv();
    const extractor: RecipeExtractor = { provider: "grok", model: "grok-4.6", extract: async () => ({ recipe: validRecipe(), provider: "grok", model: "grok-4.6" }) };
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", extractorFactory: () => extractor });
    const token = await accessToken(app, env);
    const response = await app.request("/v1/recipe-imports", importRequest(token), env);
    expect(response.status).toBe(200);
    const body = await response.json() as any;
    expect(body.requestID).toBe("safe-request-id");
    expect(body.recipe.provenance.cleanedText).toBe(pastedRecipe);
    expect(body.extraction).toEqual({ provider: "grok", model: "grok-4.6", schemaVersion: 1 });
  });

  it("requires a bearer session", async () => {
    const app = createApp();
    const response = await app.request("/v1/recipe-imports", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }, testEnv());
    expect(response.status).toBe(401);
  });

  it("rotates refresh tokens and rejects reuse", async () => {
    const env = testEnv();
    const app = createApp({ verifyApple: async () => "opaque-apple-subject" });
    const login = await app.request("/v1/session/apple", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ identityToken: "token" }) }, env);
    const first = await login.json() as { refreshToken: string };
    const init = { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ refreshToken: first.refreshToken }) };
    expect((await app.request("/v1/session/refresh", init, env)).status).toBe(200);
    expect((await app.request("/v1/session/refresh", init, env)).status).toBe(401);
  });

  it("applies rate limits before provider work", async () => {
    const extract = vi.fn();
    const env = testEnv({ IMPORT_RATE_LIMITER: { limit: async () => ({ success: false }) } });
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", extractorFactory: () => ({ provider: "grok", model: "grok-4.6", extract }) });
    const response = await app.request("/v1/recipe-imports", importRequest(await accessToken(app, env)), env);
    expect(response.status).toBe(429);
    expect(extract).not.toHaveBeenCalled();
  });

  it("coalesces simultaneous idempotent retries without retaining the result", async () => {
    const env = testEnv();
    const extract = vi.fn(async () => {
      await new Promise((resolve) => setTimeout(resolve, 25));
      return { recipe: validRecipe(), provider: "grok" as const, model: "grok-4.6" };
    });
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", extractorFactory: () => ({ provider: "grok", model: "grok-4.6", extract }) });
    const token = await accessToken(app, env);
    const [first, second] = await Promise.all([
      app.request("/v1/recipe-imports", importRequest(token, "same-key"), env),
      app.request("/v1/recipe-imports", importRequest(token, "same-key"), env)
    ]);
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(extract).toHaveBeenCalledTimes(1);
  });

  it("does not log source text or provider output", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const env = testEnv();
    const app = createApp({
      verifyApple: async () => "opaque-apple-subject",
      extractorFactory: () => ({ provider: "grok", model: "grok-4.6", extract: async () => ({ recipe: validRecipe(), provider: "grok", model: "grok-4.6" }) })
    });
    const response = await app.request("/v1/recipe-imports", importRequest(await accessToken(app, env), "redaction"), env);
    expect(response.status).toBe(200);
    expect(consoleSpy).not.toHaveBeenCalled();
    consoleSpy.mockRestore();
  });
});
