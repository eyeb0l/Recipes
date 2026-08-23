import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/index";
import type { RecipeExtractor } from "../src/providers";
import { missingServingCountMessage, missingServingCountUncertaintyID } from "../src/serving-resolution";
import type { NormalizedRecipeSource } from "../src/types";
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

function urlImportRequest(token: string, idempotencyKey: string): RequestInit {
  return {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({
      sourceType: "url",
      url: "https://www.saltandlavender.com/ravioli-alla-vodka/",
      locale: "en_GB",
      preferredUnitSystem: "metric",
      idempotencyKey
    })
  };
}

function uncertainty(id: string, message: string): any {
  return {
    id,
    kind: "other",
    severity: "warning",
    message,
    ingredientIDs: [],
    stageIDs: [],
    sourceEvidence: null,
    isResolved: false
  };
}

const publicResolver = async () => ["93.184.216.34"];

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

  it("locks an unambiguous JSON-LD recipeYield over a model placeholder", async () => {
    const html = `<script type="application/ld+json">${JSON.stringify({
      "@context": "https://schema.org",
      "@graph": [{
        "@type": "Recipe",
        name: "Ravioli alla Vodka",
        recipeYield: ["4"],
        recipeIngredient: ["1 tablespoon olive oil"],
        recipeInstructions: [{ "@type": "HowToStep", text: "Cook the ravioli in the sauce." }]
      }]
    })}</script>`;
    const extract = vi.fn(async (_source: NormalizedRecipeSource, _requestID: string) => {
      const recipe = validRecipe();
      recipe.yield = { servings: 1, label: null };
      recipe.uncertainties = [
        uncertainty("model-yield-warning", "The source does not state a yield, so 1 was used."),
        uncertainty("optional-cheese", "The recipe doesn't say whether to serve with parmesan.")
      ];
      return { recipe, provider: "openai" as const, model: "gpt-5.6-luna" };
    });
    const env = testEnv();
    const app = createApp({
      verifyApple: async () => "opaque-apple-subject",
      resolver: publicResolver,
      fetcher: async () => new Response(html, { headers: { "Content-Type": "text/html" } }),
      extractorFactory: () => ({ provider: "openai", model: "gpt-5.6-luna", extract })
    });
    const response = await app.request("/v1/recipe-imports", urlImportRequest(await accessToken(app, env), "structured-yield"), env);
    expect(response.status).toBe(200);
    const body = await response.json() as any;
    expect(extract.mock.calls[0]?.[0].structuredYield).toEqual({ servings: 4, label: "4" });
    expect(body.recipe.yield).toEqual({ servings: 4, label: "4" });
    expect(body.recipe.uncertainties.map((item: any) => item.id)).toEqual(["optional-cheese"]);
    expect(body.recipe.provenance.cleanedText).toContain("4");
  });

  it("passes readable page text to the model when structured yield is absent", async () => {
    const html = `<script type="application/ld+json">${JSON.stringify({
      "@type": "Recipe",
      name: "Soup",
      recipeIngredient: ["1 onion"],
      recipeInstructions: [{ text: "Simmer." }]
    })}</script><main><p>Servings: 6</p></main>`;
    const extract = vi.fn(async (_source: NormalizedRecipeSource, _requestID: string) => {
      const recipe = validRecipe();
      recipe.yield = { servings: 6, label: "Servings: 6" };
      recipe.uncertainties = [uncertainty("stale-yield-warning", "The source does not state a yield, so 1 was used.")];
      return { recipe, provider: "openai" as const, model: "gpt-5.6-luna" };
    });
    const env = testEnv();
    const app = createApp({
      verifyApple: async () => "opaque-apple-subject",
      resolver: publicResolver,
      fetcher: async () => new Response(html, { headers: { "Content-Type": "text/html" } }),
      extractorFactory: () => ({ provider: "openai", model: "gpt-5.6-luna", extract })
    });
    const response = await app.request("/v1/recipe-imports", urlImportRequest(await accessToken(app, env), "model-yield"), env);
    expect(response.status).toBe(200);
    expect(extract.mock.calls[0]?.[0].structuredYield).toBeUndefined();
    expect(extract.mock.calls[0]?.[0].pageText).toContain("Servings: 6");
    const recipe = (await response.json() as any).recipe;
    expect(recipe.yield).toEqual({ servings: 6, label: "Servings: 6" });
    expect(recipe.uncertainties).toEqual([]);
  });

  it("adds one plain-language placeholder warning only when serving extraction fails", async () => {
    const html = `<script type="application/ld+json">${JSON.stringify({
      "@type": "Recipe",
      name: "Soup",
      recipeIngredient: ["1 onion"],
      recipeInstructions: [{ text: "Simmer." }]
    })}</script>`;
    const extract = vi.fn(async (_source: NormalizedRecipeSource, _requestID: string) => {
      const recipe = validRecipe();
      recipe.yield = { servings: 1, label: null };
      recipe.uncertainties = [uncertainty("salt-placement", "The recipe doesn't say when to add the salt.")];
      return { recipe, provider: "openai" as const, model: "gpt-5.6-luna" };
    });
    const env = testEnv();
    const app = createApp({
      verifyApple: async () => "opaque-apple-subject",
      resolver: publicResolver,
      fetcher: async () => new Response(html, { headers: { "Content-Type": "text/html" } }),
      extractorFactory: () => ({ provider: "openai", model: "gpt-5.6-luna", extract })
    });
    const response = await app.request("/v1/recipe-imports", urlImportRequest(await accessToken(app, env), "missing-yield"), env);
    expect(response.status).toBe(200);
    const recipe = (await response.json() as any).recipe;
    expect(recipe.yield).toEqual({ servings: 1, label: null });
    expect(recipe.uncertainties).toEqual([
      uncertainty(missingServingCountUncertaintyID, missingServingCountMessage),
      uncertainty("salt-placement", "The recipe doesn't say when to add the salt.")
    ]);
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
