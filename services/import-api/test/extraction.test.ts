import { describe, expect, it, vi } from "vitest";
import { extractRecipeFromHTML } from "../src/extraction/html-recipe";
import { fetchPublicRecipe, isForbiddenHostname, parsePublicURL } from "../src/extraction/public-fetch";

describe("layered page extraction", () => {
  it("prefers recipe JSON-LD", () => {
    const html = `<script type="application/ld+json">{"@type":"Recipe","name":"Soup","recipeIngredient":["1 onion"],"recipeInstructions":[{"text":"Simmer."}]}</script>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({ method: "json-ld", title: "Soup", ingredients: ["1 onion"], instructions: ["Simmer."] });
  });

  it("falls back when JSON-LD is malformed", () => {
    const html = `<script type="application/ld+json">{broken</script><article>${"Readable recipe prose. ".repeat(10)}</article>`;
    expect(extractRecipeFromHTML(html).method).toBe("cleaned-prose");
  });
});

describe("public URL safety", () => {
  it.each(["localhost", "127.0.0.1", "10.1.2.3", "169.254.10.3", "192.168.0.1", "::1", "fd00::1", "service.local"])("blocks %s", (host) => {
    expect(isForbiddenHostname(host)).toBe(true);
  });

  it("rejects credentials and non-http protocols", () => {
    expect(() => parsePublicURL("file:///etc/passwd")).toThrow();
    expect(() => parsePublicURL("https://name:password@example.com/recipe")).toThrow();
  });

  it("revalidates every redirect target", async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(input.toString());
      if (url.hostname === "example.com") return new Response(null, { status: 302, headers: { Location: "http://127.0.0.1/secret" } });
      return new Response("should not fetch");
    });
    await expect(fetchPublicRecipe("https://example.com/recipe", fetcher, async () => ["93.184.216.34"]))
      .rejects.toMatchObject({ code: "private_network_url" });
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("enforces streamed response limits", async () => {
    const fetcher = vi.fn(async () => new Response("x".repeat(2_000_001), { headers: { "Content-Type": "text/html" } }));
    await expect(fetchPublicRecipe("https://example.com/recipe", fetcher, async () => ["93.184.216.34"]))
      .rejects.toMatchObject({ code: "source_too_large" });
  });
});
