import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestHarness } from "wrangler";
import { issueSession } from "../src/auth/session";
import { createApp } from "../src/index";
import { fixtureSubjectHash, testEnv, validRecipe } from "./fixtures";

describe("daily quotas in workerd", () => {
  const harness = createTestHarness({ workers: [{ configPath: "./wrangler.jsonc" }] });
  const worker = harness.getWorker();
  let runtime: Env;
  let env: Env;

  beforeAll(async () => {
    await harness.listen();
    runtime = await worker.getEnv() as Env;
    env = testEnv({ DAILY_QUOTA: runtime.DAILY_QUOTA });
  }, 20_000);
  afterAll(() => harness.close());

  it("admits just one of a concurrent import and generation competing for the final daily slot", async () => {
    const subject = "shared-provider-allowance";
    const hash = await fixtureSubjectHash(subject);
    const day = new Date().toISOString().slice(0, 10);
    // Seed usage already recorded by the previous Worker, before either caller reaches the object.
    await runtime.SESSIONS.put(`quota:${day}:${hash}`, "19");
    const extract = vi.fn(async () => ({ recipe: validRecipe(), provider: "openai" as const, model: "fixture" }));
    const generate = vi.fn(async () => ({ recipe: validRecipe(), provider: "openai" as const, model: "fixture", webSearch: false, sources: [] }));
    const app = createApp({
      extractorFactory: () => ({ provider: "openai", model: "fixture", extract }),
      generatorFactory: () => ({ provider: "openai", model: "fixture", webSearch: false, generate })
    });
    const { accessToken } = await issueSession(env, subject);
    const importBody = { sourceType: "text", text: "Mix flour with water to make a smooth batter. Cook until golden." };
    const responses = await Promise.all([
      app.request("/v1/recipe-imports", request(accessToken, "import-final-slot", importBody), env),
      app.request("/v1/recipe-generations", request(accessToken, "generation-final-slot", { request: "Quick pancakes for two" }), env)
    ]);

    expect(responses.map((response) => response.status).sort()).toEqual([200, 429]);
    expect(await responses.find((response) => response.status === 429)!.json()).toMatchObject({ error: { code: "quota_exceeded" } });
    expect(extract.mock.calls.length + generate.mock.calls.length).toBe(1);

    const afterLimit = await app.request("/v1/recipe-imports", request(accessToken, "after-limit", importBody), env);
    expect(afterLimit.status).toBe(429);
    expect(extract.mock.calls.length + generate.mock.calls.length).toBe(1);

    const other = await issueSession(env, "another-subject");
    const otherResponse = await app.request("/v1/recipe-imports", request(other.accessToken, "other-subject", importBody), env);
    expect(otherResponse.status).toBe(200);
  });

  it("admits one outbound fetch at the limit even when the page cannot be used", async () => {
    const subject = "shared-fetch-allowance";
    const hash = await fixtureSubjectHash(subject);
    const day = new Date().toISOString().slice(0, 10);
    await runtime.SESSIONS.put(`fetch-quota:${day}:${hash}`, "39");
    const extract = vi.fn();
    const fetcher = vi.fn(async () => new Response("not found", { status: 404 }));
    const app = createApp({
      extractorFactory: () => ({ provider: "openai", model: "fixture", extract }),
      resolver: async () => ["93.184.216.34"],
      fetcher
    });
    const { accessToken } = await issueSession(env, subject);
    const urlBody = { sourceType: "url", url: "https://example.com/recipe" };
    const responses = await Promise.all(["fetch-one", "fetch-two"].map((key) =>
      app.request("/v1/recipe-imports", request(accessToken, key, urlBody), env)
    ));

    expect(responses.map((response) => response.status).sort()).toEqual([422, 429]);
    expect(await responses.find((response) => response.status === 429)!.json()).toMatchObject({ error: { code: "fetch_quota_exceeded" } });
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(extract).not.toHaveBeenCalled();
  });
});

function request(token: string, idempotencyKey: string, body: Record<string, unknown>): RequestInit {
  return {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ ...body, locale: "en_GB", preferredUnitSystem: "metric", idempotencyKey })
  };
}
