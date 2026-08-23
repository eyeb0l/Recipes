import { describe, expect, it, vi } from "vitest";
import { extractRecipeFromHTML } from "../src/extraction/html-recipe";
import { fetchPublicRecipe, isForbiddenHostname, parsePublicURL } from "../src/extraction/public-fetch";

describe("layered page extraction", () => {
  it("prefers recipe JSON-LD", () => {
    const html = `<script type="application/ld+json">{"@type":"Recipe","name":"Soup","recipeIngredient":["1 onion"],"recipeInstructions":[{"text":"Simmer."}]}</script>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({ method: "json-ld", title: "Soup", ingredients: ["1 onion"], instructions: ["Simmer."] });
  });

  it("uses Salt & Lavender-shaped recipeYield arrays and keeps readable fallback text", () => {
    const html = `
      <article><h1>Ravioli alla Vodka</h1><p>Prep: 10 mins. Cook: 10 mins. Servings: 4.</p></article>
      <script type="application/ld+json">{
        "@context":"https://schema.org",
        "@graph":[{
          "@type":"Recipe",
          "name":"Ravioli alla Vodka",
          "recipeYield":["4"],
          "recipeIngredient":["1 tablespoon olive oil"],
          "recipeInstructions":[{"@type":"HowToStep","text":"Cook the ravioli."}]
        }]
      }</script>`;
    const extracted = extractRecipeFromHTML(html);
    expect(extracted).toMatchObject({
      method: "json-ld",
      structuredYield: { servings: 4, label: "4" }
    });
    expect(extracted.cleanedText).toContain("Yield\n4");
    expect(extracted.pageText).toContain("Servings: 4.");
  });

  it("supports JSON-LD QuantitativeValue yields", () => {
    const html = `<script type="application/ld+json">{
      "@type":"Recipe",
      "recipeYield":{"@type":"QuantitativeValue","value":4,"unitText":"servings"},
      "recipeIngredient":["1 onion"],
      "recipeInstructions":["Simmer."]
    }</script>`;
    expect(extractRecipeFromHTML(html).structuredYield).toEqual({ servings: 4, label: "4 servings" });
  });

  it("does not treat a QuantitativeValue volume as a serving count", () => {
    const html = `<script type="application/ld+json">{
      "@type":"Recipe",
      "recipeYield":{"@type":"QuantitativeValue","value":500,"unitText":"ml"},
      "recipeIngredient":["1 onion"],
      "recipeInstructions":["Simmer."]
    }</script>`;
    const extracted = extractRecipeFromHTML(html);
    expect(extracted.structuredYield).toBeUndefined();
    expect(extracted.pageText).toContain("Recipe yield: 500 ml");
  });

  it("supports numeric JSON-LD yields without inventing a source label", () => {
    const html = `<script type="application/ld+json">{
      "@type":"Recipe",
      "recipeYield":4,
      "recipeIngredient":["1 onion"],
      "recipeInstructions":["Simmer."]
    }</script>`;
    expect(extractRecipeFromHTML(html).structuredYield).toEqual({ servings: 4, label: null });
  });

  it.each([
    ["omits yield", undefined],
    ["has an ambiguous yield", "2-4 servings"]
  ])("uses unambiguous Recipe microdata when JSON-LD %s", (_description, recipeYield) => {
    const html = `
      <script type="application/ld+json">${JSON.stringify({
        "@type": "Recipe",
        name: "Soup",
        ...(recipeYield ? { recipeYield } : {}),
        recipeIngredient: ["1 onion"],
        recipeInstructions: ["Simmer."]
      })}</script>
      <article itemscope itemtype="https://schema.org/Recipe">
        <meta itemprop="name" content="Soup">
        <meta itemprop="recipeYield" content="4 servings">
      </article>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({
      method: "json-ld",
      structuredYield: { servings: 4, label: "4 servings" },
      ingredients: ["1 onion"]
    });
  });

  it("keeps an unambiguous JSON-LD yield authoritative over conflicting microdata", () => {
    const html = `
      <script type="application/ld+json">${JSON.stringify({
        "@type": "Recipe",
        recipeYield: "4 servings",
        recipeIngredient: ["1 onion"],
        recipeInstructions: ["Simmer."]
      })}</script>
      <article itemscope itemtype="https://schema.org/Recipe">
        <meta itemprop="name" content="Soup">
        <meta itemprop="recipeYield" content="6 servings">
      </article>`;
    expect(extractRecipeFromHTML(html).structuredYield).toEqual({ servings: 4, label: "4 servings" });
  });

  it("does not borrow yield from unrelated Recipe microdata", () => {
    const html = `
      <script type="application/ld+json">${JSON.stringify({
        "@type": "Recipe",
        name: "Main soup",
        recipeIngredient: ["1 onion"],
        recipeInstructions: ["Simmer."]
      })}</script>
      <aside itemscope itemtype="https://schema.org/Recipe">
        <meta itemprop="name" content="Related cake">
        <meta itemprop="recipeYield" content="12 slices">
      </aside>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({
      method: "json-ld",
      title: "Main soup",
      structuredYield: undefined
    });
  });

  it("keeps pure microdata recipe fields and yield in the same Recipe scope", () => {
    const html = `
      <article itemscope itemtype="https://schema.org/Recipe">
        <meta itemprop="name" content="Main soup">
        <span itemprop="recipeIngredient">1 onion</span>
        <p itemprop="recipeInstructions">Simmer.</p>
      </article>
      <aside itemscope itemtype="https://schema.org/Recipe">
        <meta itemprop="name" content="Related cake">
        <meta itemprop="recipeYield" content="12 slices">
      </aside>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({
      method: "microdata",
      title: "Main soup",
      structuredYield: undefined,
      ingredients: ["1 onion"],
      instructions: ["Simmer."]
    });
  });

  it.each([
    ["an ambiguous range", "4-6 servings"],
    ["a sub-unit count", "0.5 servings"],
    ["a spaced volume yield", "500 ml"],
    ["a compact volume yield", "500ml"],
    ["a multiplied count", "2 dozen cookies"],
    ["an energy value", "500 kcal"]
  ])("leaves %s unresolved", (_description, recipeYield) => {
    const html = `<script type="application/ld+json">${JSON.stringify({
      "@type": "Recipe",
      recipeYield,
      recipeIngredient: ["1 onion"],
      recipeInstructions: ["Simmer."]
    })}</script>`;
    expect(extractRecipeFromHTML(html).structuredYield).toBeUndefined();
  });

  it("keeps an unresolved raw JSON-LD yield available for model fallback", () => {
    const html = `<script type="application/ld+json">{
      "@type":"Recipe",
      "recipeYield":"2-4 servings",
      "recipeIngredient":["1 onion"],
      "recipeInstructions":["Simmer."]
    }</script>`;
    const extracted = extractRecipeFromHTML(html);
    expect(extracted.structuredYield).toBeUndefined();
    expect(extracted.pageText).toContain("Recipe yield: 2-4 servings");
  });

  it("leaves conflicting recipeYield array values unresolved", () => {
    const html = `<script type="application/ld+json">{
      "@type":"Recipe",
      "recipeYield":["4 servings","6 servings"],
      "recipeIngredient":["1 onion"],
      "recipeInstructions":["Simmer."]
    }</script>`;
    expect(extractRecipeFromHTML(html).structuredYield).toBeUndefined();
  });

  it.each([
    ["content attribute", `<meta itemprop="recipeYield" content="4 servings">`, "4 servings"],
    ["paired tag", `<span itemprop="recipeYield">Serves 4</span>`, "Serves 4"]
  ])("extracts microdata recipeYield from a %s", (_description, yieldMarkup, label) => {
    const html = `
      <article itemscope itemtype="https://schema.org/Recipe">
        <h1 itemprop="name">Soup</h1>
        ${yieldMarkup}
        <span itemprop="recipeIngredient">1 onion</span>
        <p itemprop="recipeInstructions">Simmer.</p>
      </article>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({
      method: "microdata",
      structuredYield: { servings: 4, label }
    });
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
