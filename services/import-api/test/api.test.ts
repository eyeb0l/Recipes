import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/index";
import type { RecipeExtractor } from "../src/providers";
import { missingServingCountMessage, missingServingCountUncertaintyID } from "../src/serving-resolution";
import type { NormalizedRecipeSource } from "../src/types";
import { MemoryKV, testEnv, validRecipe } from "./fixtures";

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
    const extractor: RecipeExtractor = { provider: "openai", model: "gpt-6.1-terra", extract: async () => ({ recipe: validRecipe(), provider: "openai", model: "gpt-6.1-terra" }) };
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", extractorFactory: () => extractor });
    const token = await accessToken(app, env);
    const response = await app.request("/v1/recipe-imports", importRequest(token), env);
    expect(response.status).toBe(200);
    const body = await response.json() as any;
    expect(body.requestID).toBe("safe-request-id");
    expect(body.recipe.provenance.cleanedText).toBe(pastedRecipe);
    expect(body.extraction).toEqual({ provider: "openai", model: "gpt-6.1-terra", schemaVersion: 1 });
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
      return { recipe, provider: "openai" as const, model: "gpt-6.1-terra" };
    });
    const env = testEnv();
    const app = createApp({
      verifyApple: async () => "opaque-apple-subject",
      resolver: publicResolver,
      fetcher: async () => new Response(html, { headers: { "Content-Type": "text/html" } }),
      extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract })
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
      return { recipe, provider: "openai" as const, model: "gpt-6.1-terra" };
    });
    const env = testEnv();
    const app = createApp({
      verifyApple: async () => "opaque-apple-subject",
      resolver: publicResolver,
      fetcher: async () => new Response(html, { headers: { "Content-Type": "text/html" } }),
      extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract })
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
      return { recipe, provider: "openai" as const, model: "gpt-6.1-terra" };
    });
    const env = testEnv();
    const app = createApp({
      verifyApple: async () => "opaque-apple-subject",
      resolver: publicResolver,
      fetcher: async () => new Response(html, { headers: { "Content-Type": "text/html" } }),
      extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract })
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
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract }) });
    const response = await app.request("/v1/recipe-imports", importRequest(await accessToken(app, env)), env);
    expect(response.status).toBe(429);
    expect(extract).not.toHaveBeenCalled();
  });

  it("coalesces simultaneous idempotent retries without retaining the result", async () => {
    const env = testEnv();
    const extract = vi.fn(async () => {
      await new Promise((resolve) => setTimeout(resolve, 25));
      return { recipe: validRecipe(), provider: "openai" as const, model: "gpt-6.1-terra" };
    });
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract }) });
    const token = await accessToken(app, env);
    const [first, second] = await Promise.all([
      app.request("/v1/recipe-imports", importRequest(token, "same-key"), env),
      app.request("/v1/recipe-imports", importRequest(token, "same-key"), env)
    ]);
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(extract).toHaveBeenCalledTimes(1);
  });

  it("does not spend the daily allowance on invalid sources or coalesced retries", async () => {
    const env = testEnv();
    const kv = env.SESSIONS as unknown as MemoryKV;
    const quotaValue = () => [...kv.values.entries()].find(([key]) => key.startsWith("quota:"))?.[1];
    const extract = vi.fn(async () => {
      await new Promise((resolve) => setTimeout(resolve, 10));
      return { recipe: validRecipe(), provider: "openai" as const, model: "gpt-6.1-terra" };
    });
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract }) });
    const token = await accessToken(app, env);

    const tooShort = await app.request("/v1/recipe-imports", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sourceType: "text", text: "too short", locale: "en_GB", preferredUnitSystem: "metric", idempotencyKey: "invalid" })
    }, env);
    expect(tooShort.status).toBe(400);
    expect(quotaValue()).toBeUndefined();

    const [first, retry] = await Promise.all([
      app.request("/v1/recipe-imports", importRequest(token, "quota-key"), env),
      app.request("/v1/recipe-imports", importRequest(token, "quota-key"), env)
    ]);
    expect(first.status).toBe(200);
    expect(retry.status).toBe(200);
    expect(extract).toHaveBeenCalledTimes(1);
    expect(quotaValue()).toBe("1");
  });

  it("lets a retry join in-flight work that used the last daily import", async () => {
    const limit = vi.fn(async () => ({ success: true }));
    const env = testEnv({ IMPORT_RATE_LIMITER: { limit } });
    const kv = env.SESSIONS as unknown as MemoryKV;
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("opaque-apple-subject"));
    const subject = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
    const quotaKey = `quota:${new Date().toISOString().slice(0, 10)}:${subject}`;
    kv.values.set(quotaKey, "19");
    let release: () => void = () => undefined;
    const extract = vi.fn();
    const fetcher = vi.fn(async () => new Response(`<script type="application/ld+json">${JSON.stringify({
      "@type": "Recipe", name: "Pancakes", recipeYield: "2", recipeIngredient: ["100 g flour"], recipeInstructions: ["Mix and cook."]
    })}</script>`, { headers: { "Content-Type": "text/html" } }));
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", fetcher, resolver: publicResolver, extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract }) });
    const token = await accessToken(app, env);

    for (const request of [importRequest, urlImportRequest]) {
      kv.values.set(quotaKey, "19");
      const pending = new Promise<void>((resolve) => { release = resolve; });
      extract.mockReset();
      limit.mockClear();
      fetcher.mockClear();
      extract.mockImplementation(async () => {
        await pending;
        return { recipe: validRecipe(), provider: "openai" as const, model: "gpt-6.1-terra" };
      });
      const key = `last-import-${request.name}`;
      const first = app.request("/v1/recipe-imports", request(token, key), env);
      await vi.waitFor(() => expect(extract).toHaveBeenCalledTimes(1));
      expect(kv.values.get(quotaKey)).toBe("20");
      const retry = app.request("/v1/recipe-imports", request(token, key), env);
      // Hold the first import open until the retry is past admission (and, for links, its page fetch),
      // then leave a margin for it to join; a fixed short delay flaked on loaded machines.
      await vi.waitFor(() => expect(limit).toHaveBeenCalledTimes(2));
      if (request === urlImportRequest) await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2));
      await new Promise((resolve) => setTimeout(resolve, 50));
      release();
      const [firstResponse, retryResponse] = await Promise.all([first, retry]);
      expect(firstResponse.status).toBe(200);
      expect(retryResponse.status).toBe(200);
      expect(extract).toHaveBeenCalledTimes(1);
      expect(kv.values.get(quotaKey)).toBe("20");
    }
  });

  it("charges the fetch allowance for a retry that joins in-flight URL work", async () => {
    const env = testEnv();
    const kv = env.SESSIONS as unknown as MemoryKV;
    let release: () => void = () => undefined;
    const pending = new Promise<void>((resolve) => { release = resolve; });
    const extract = vi.fn(async () => {
      await pending;
      return { recipe: validRecipe(), provider: "openai" as const, model: "gpt-6.1-terra" };
    });
    const fetcher = vi.fn(async () => new Response(`<script type="application/ld+json">${JSON.stringify({
      "@type": "Recipe", name: "Pancakes", recipeYield: "2", recipeIngredient: ["100 g flour"], recipeInstructions: ["Mix and cook."]
    })}</script>`, { headers: { "Content-Type": "text/html" } }));
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", fetcher, resolver: publicResolver, extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract }) });
    const token = await accessToken(app, env);

    const first = app.request("/v1/recipe-imports", urlImportRequest(token, "shared-key"), env);
    await vi.waitFor(() => expect(extract).toHaveBeenCalledTimes(1));
    const fetchKey = [...kv.values.keys()].find((key) => key.startsWith("fetch-quota:"))!;
    kv.values.set(fetchKey, "40");
    const reused = await app.request("/v1/recipe-imports", urlImportRequest(token, "shared-key"), env);
    expect(reused.status).toBe(429);
    expect((await reused.json() as any).error.code).toBe("fetch_quota_exceeded");
    expect(fetcher).toHaveBeenCalledTimes(1);
    release();
    expect((await first).status).toBe(200);
  });

  it("rejects work once the daily allowance is used without fetching the source or calling the provider", async () => {
    const env = testEnv();
    const extract = vi.fn();
    const fetcher = vi.fn(async () => new Response("<html></html>", { headers: { "Content-Type": "text/html" } }));
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", fetcher, resolver: publicResolver, extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract }) });
    const token = await accessToken(app, env);
    const kv = env.SESSIONS as unknown as MemoryKV;
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("opaque-apple-subject"));
    const subject = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
    kv.values.set(`quota:${new Date().toISOString().slice(0, 10)}:${subject}`, "20");
    const response = await app.request("/v1/recipe-imports", importRequest(token, "over-quota"), env);
    expect(response.status).toBe(429);
    expect((await response.json() as any).error.code).toBe("quota_exceeded");
    const urlResponse = await app.request("/v1/recipe-imports", urlImportRequest(token, "over-quota-url"), env);
    expect(urlResponse.status).toBe(429);
    expect(fetcher).not.toHaveBeenCalled();
    expect(extract).not.toHaveBeenCalled();
  });

  it("limits outbound page fetches per day even when the fetched page can't be used", async () => {
    const env = testEnv();
    const kv = env.SESSIONS as unknown as MemoryKV;
    const extract = vi.fn();
    const fetcher = vi.fn(async () => new Response("not found", { status: 404, headers: { "Content-Type": "text/html" } }));
    const app = createApp({ verifyApple: async () => "opaque-apple-subject", fetcher, resolver: publicResolver, extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract }) });
    const token = await accessToken(app, env);

    const failed = await app.request("/v1/recipe-imports", urlImportRequest(token, "missing-page"), env);
    expect(failed.status).toBeGreaterThanOrEqual(400);
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect([...kv.values.entries()].find(([key]) => key.startsWith("fetch-quota:"))?.[1]).toBe("1");
    expect([...kv.values.keys()].some((key) => key.startsWith("quota:"))).toBe(false);

    const fetchKey = [...kv.values.keys()].find((key) => key.startsWith("fetch-quota:"))!;
    kv.values.set(fetchKey, "40");
    const limited = await app.request("/v1/recipe-imports", urlImportRequest(token, "another-page"), env);
    expect(limited.status).toBe(429);
    expect((await limited.json() as any).error.code).toBe("fetch_quota_exceeded");
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(extract).not.toHaveBeenCalled();
  });

  it("does not log source text or provider output", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const env = testEnv();
    const app = createApp({
      verifyApple: async () => "opaque-apple-subject",
      extractorFactory: () => ({ provider: "openai", model: "gpt-6.1-terra", extract: async () => ({ recipe: validRecipe(), provider: "openai", model: "gpt-6.1-terra" }) })
    });
    const response = await app.request("/v1/recipe-imports", importRequest(await accessToken(app, env), "redaction"), env);
    expect(response.status).toBe(200);
    expect(consoleSpy).not.toHaveBeenCalled();
    consoleSpy.mockRestore();
  });
});
