import { describe, expect, it, vi } from "vitest";
import { GrokExtractor } from "../src/providers/grok-extractor";
import { OpenAIExtractor } from "../src/providers/openai-extractor";
import { createExtractor } from "../src/providers";
import type { NormalizedRecipeSource } from "../src/types";
import { testEnv, validRecipe } from "./fixtures";

const source: NormalizedRecipeSource = {
  sourceType: "text", prose: "Mix 100 g flour with water to make two pancakes.", images: [], locale: "en_GB", preferredUnitSystem: "metric"
};

describe("provider adapters", () => {
  it("defaults the deployment to OpenAI Luna and keeps Grok explicit", () => {
    const active = createExtractor(testEnv());
    expect(active.provider).toBe("openai");
    expect(active.model).toBe("gpt-5.6-luna");

    const legacy = createExtractor(testEnv({ RECIPE_PROVIDER: "grok" }));
    expect(legacy.provider).toBe("grok");
    expect(legacy.model).toBe("grok-4.6");
  });

  it("sends Grok the strict shared schema without fallback", async () => {
    const fetcher = vi.fn(async (_url: RequestInfo | URL, init?: RequestInit) => new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(validRecipe()) } }] }), { status: 200 }));
    const result = await new GrokExtractor("grok-4.6", "xai-test", fetcher as typeof fetch).extract(source, "request-1");
    const body = JSON.parse(fetcher.mock.calls[0]![1]!.body as string);
    expect(body.model).toBe("grok-4.6");
    expect(body.reasoning_effort).toBe("low");
    expect(body.response_format.json_schema.strict).toBe(true);
    expect(result.provider).toBe("grok");
  });

  it("uses low reasoning, Responses structured output, and disables storage for OpenAI", async () => {
    const fetcher = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) => new Response(JSON.stringify({ output: [{ content: [{ type: "output_text", text: JSON.stringify(validRecipe()) }] }] }), { status: 200 }));
    const result = await new OpenAIExtractor("gpt-5.6-luna", "sk-test", fetcher as typeof fetch).extract(source, "request-2");
    const body = JSON.parse(fetcher.mock.calls[0]![1]!.body as string);
    expect(body.model).toBe("gpt-5.6-luna");
    expect(body.store).toBe(false);
    expect(body.reasoning.effort).toBe("low");
    expect(body.text.format.strict).toBe(true);
    expect(result.provider).toBe("openai");
  });

  it("does not silently substitute on provider failure", async () => {
    const fetcher = vi.fn(async () => new Response("denied", { status: 403 }));
    await expect(new GrokExtractor("grok-4.6", "xai-test", fetcher as typeof fetch).extract(source, "request-3"))
      .rejects.toMatchObject({ code: "provider_error" });
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("reports provider timeouts without exposing an internal error", async () => {
    const timeout = Object.assign(new Error("request aborted"), { name: "TimeoutError" });
    const fetcher = vi.fn(async () => { throw timeout; });
    await expect(new GrokExtractor("grok-4.6", "xai-test", fetcher as typeof fetch).extract(source, "request-4"))
      .rejects.toMatchObject({ status: 504, code: "provider_timeout" });
  });

  it("reports provider transport failures without exposing an internal error", async () => {
    const fetcher = vi.fn(async () => { throw new TypeError("network unavailable"); });
    await expect(new OpenAIExtractor("gpt-5.6-luna", "sk-test", fetcher as typeof fetch).extract(source, "request-5"))
      .rejects.toMatchObject({ status: 503, code: "provider_unavailable" });
  });
});
