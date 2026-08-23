import { describe, expect, it } from "vitest";
import { cleanHTML, extractRecipeFromHTML } from "../src/extraction/html-recipe";
import { isGenericLandingRedirect, prepareImportRequest } from "../src/import-request";
import { extractionPrompt } from "../src/providers/recipe-extractor";
import { missingServingCountMessage, resolveRecipeServingCount } from "../src/serving-resolution";
import type { NormalizedRecipeSource } from "../src/types";

function recipeJSONLD(recipeYield: unknown, extra: Record<string, unknown> = {}): string {
  return JSON.stringify({
    "@context": "https://schema.org",
    "@type": "Recipe",
    name: "Compatibility recipe",
    recipeYield,
    recipeIngredient: ["1 onion", "1 tablespoon oil"],
    recipeInstructions: [
      { "@type": "HowToStep", text: "Cook the onion." },
      { "@type": "HowToStep", text: "Serve immediately." }
    ],
    ...extra
  });
}

function extractedYield(recipeYield: unknown) {
  return extractRecipeFromHTML(
    `<script type="application/ld+json">${recipeJSONLD(recipeYield)}</script>`
  ).structuredYield;
}

describe("popular recipe-site JSON-LD compatibility", () => {
  it("accepts an unquoted application/ld+json type attribute", () => {
    const html = `<script type=application/ld+json>${recipeJSONLD("4 servings")}</script>`;

    expect(extractRecipeFromHTML(html)).toMatchObject({
      method: "json-ld",
      title: "Compatibility recipe",
      structuredYield: { servings: 4, label: "4 servings" }
    });
  });

  it("accepts flexible script attributes and full Schema.org type IRIs", () => {
    const html = `<script class="schema" type = "application/ld+json; charset=utf-8">${JSON.stringify({
      "@type": "https://schema.org/Recipe",
      name: "Full IRI soup",
      recipeYield: { "@type": "https://schema.org/QuantitativeValue", value: 4, unitCode: "C62", unitText: "servings" },
      recipeIngredient: ["1 onion"],
      recipeInstructions: [{ "@value": "Simmer." }]
    })}</script>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({
      method: "json-ld",
      title: "Full IRI soup",
      structuredYield: { servings: 4, label: "4 servings" },
      instructions: ["Simmer."]
    });
  });

  it("parses valid raw JSON before decoding entity text inside its string values", () => {
    const html = `<script type="application/ld+json">${recipeJSONLD("4 servings", { name: "Tea &quot;Cake&quot;" })}</script>`;
    expect(extractRecipeFromHTML(html).title).toBe('Tea "Cake"');
  });

  it.each([
    [["16", "16 XL cookies or 20 medium/large cookies"], 16],
    [["6", "6 1 cup each"], 6],
    [["4", "4 - 5 people"], 4]
  ])("uses the canonical first count in WordPress-style recipeYield arrays: %j", (recipeYield, servings) => {
    expect(extractedYield(recipeYield)).toMatchObject({ servings });
  });

  it.each([
    [["500", "500 ml"]],
    ["500 (ml) sauce"],
    [["500", { "@type": "QuantitativeValue", value: 500, unitCode: "MLT" }]],
    [["4", { "@type": "QuantitativeValue", value: 4, minValue: 2, maxValue: 4 }]]
  ])("does not let canonical-first or dimensional parsing bypass non-count units: %j", (recipeYield) => {
    expect(extractedYield(recipeYield)).toBeUndefined();
  });

  it.each([
    ["18 5-inch cookies", 18],
    ["Makes about 28 large (4½-inch) cookies", 28]
  ])("distinguishes the produced count from a product dimension in %j", (recipeYield, servings) => {
    expect(extractedYield(recipeYield)).toEqual({ servings, label: recipeYield });
  });

  it("does not mistake a product dimension for a serving count", () => {
    expect(extractedYield("9-inch cake")).toBeUndefined();
  });

  it("selects a complete recipe when an incomplete Recipe node appears first", () => {
    const html = `<script type="application/ld+json">${JSON.stringify({
      "@context": "https://schema.org",
      "@graph": [
        { "@type": "Recipe", name: "Breadcrumb recipe" },
        {
          "@type": "Recipe",
          name: "Main tomato soup",
          recipeYield: "6 bowls",
          recipeIngredient: ["8 tomatoes", "1 onion", "500 ml stock"],
          recipeInstructions: [
            { "@type": "HowToStep", text: "Roast the tomatoes." },
            { "@type": "HowToStep", text: "Blend with the stock." }
          ]
        }
      ]
    })}</script>`;

    expect(extractRecipeFromHTML(html)).toMatchObject({
      method: "json-ld",
      title: "Main tomato soup",
      structuredYield: { servings: 6, label: "6 bowls" },
      ingredients: ["8 tomatoes", "1 onion", "500 ml stock"]
    });
  });

  it("prefers the main complete Recipe node over a smaller related recipe card", () => {
    const html = `<main><h1>Main tomato soup</h1></main><script type="application/ld+json">${JSON.stringify({
      "@context": "https://schema.org",
      "@graph": [
        {
          "@type": "Recipe",
          name: "Related croutons",
          recipeYield: "2 servings",
          recipeIngredient: ["Bread"],
          recipeInstructions: ["Toast."]
        },
        {
          "@type": "Recipe",
          name: "Main tomato soup",
          recipeYield: "6 bowls",
          recipeIngredient: ["8 tomatoes", "1 onion", "500 ml stock"],
          recipeInstructions: ["Roast the tomatoes.", "Blend with the stock.", "Season and serve."]
        }
      ]
    })}</script>`;

    expect(extractRecipeFromHTML(html)).toMatchObject({
      title: "Main tomato soup",
      structuredYield: { servings: 6, label: "6 bowls" }
    });
  });

  it("honors a WebPage mainEntity reference over a larger related recipe", () => {
    const html = `<script type="application/ld+json">${JSON.stringify({
      "@graph": [
        { "@type": "WebPage", mainEntity: { "@id": "#main" } },
        {
          "@id": "#related", "@type": "Recipe", name: "Large related cake", recipeYield: "99 slices",
          recipeIngredient: Array.from({ length: 20 }, (_, index) => `Ingredient ${index}`),
          recipeInstructions: Array.from({ length: 20 }, (_, index) => `Step ${index}`)
        },
        {
          "@id": "#main", "@type": "Recipe", name: "Main soup", recipeYield: "4 bowls",
          recipeIngredient: ["1 onion"], recipeInstructions: ["Simmer."]
        }
      ]
    })}</script>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({ title: "Main soup", structuredYield: { servings: 4, label: "4 bowls" } });
  });

  it("ignores Recipe JSON-LD inside comments and templates", () => {
    const decoy = `<script type="application/ld+json">${recipeJSONLD("99 servings", { name: "Decoy" })}</script>`;
    const html = `<!-- ${decoy} --><template>${decoy}</template><script type="application/ld+json">${recipeJSONLD("4 servings")}</script>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({ title: "Compatibility recipe", structuredYield: { servings: 4 } });
  });

  it("ignores JSON-LD and headings inside nested templates", () => {
    const decoy = `<script type="application/ld+json">${recipeJSONLD("99 servings", { name: "Decoy" })}</script>`;
    const html = `<template><template></template>${decoy}<h1>Decoy</h1></template><h1>Main soup</h1>
      <script type="application/ld+json">${recipeJSONLD("4 servings", { name: "Main soup" })}</script>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({ title: "Main soup", structuredYield: { servings: 4 } });
  });

  it("ignores heading-like strings embedded in scripts when ranking recipes", () => {
    const html = `<script>window.card = "<h1>Related cake</h1>";</script><h1>Main soup</h1>
      <script type="application/ld+json">${JSON.stringify({
        "@context": "https://schema.org",
        "@graph": [
          {
            "@type": "Recipe",
            name: "Related cake",
            recipeYield: "99 slices",
            recipeIngredient: ["Flour", "Sugar"],
            recipeInstructions: [{ "@type": "HowToStep", text: "Bake." }]
          },
          {
            "@type": "Recipe",
            name: "Main soup",
            recipeYield: "4 servings",
            recipeIngredient: ["Tomatoes"],
            recipeInstructions: [{ "@type": "HowToStep", text: "Simmer." }]
          }
        ]
      })}</script>`;

    expect(extractRecipeFromHTML(html)).toMatchObject({ title: "Main soup", structuredYield: { servings: 4 } });
  });
});

describe("yield unit compatibility and safety", () => {
  it.each([
    ["a volume unitCode", { "@type": "QuantitativeValue", value: 500, unitCode: "MLT" }],
    ["a dimensioned volume name", { "@type": "QuantitativeValue", value: 500, name: "500 millilitres" }],
    ["a dozen unitText", { "@type": "QuantitativeValue", value: 2, unitText: "dozen" }],
    ["a legacy grammes unitText", { "@type": "QuantitativeValue", value: 500, unitText: "grammes" }],
    ["an abbreviated mls unitText", { "@type": "QuantitativeValue", value: 500, unitText: "mls" }]
  ])("does not turn QuantitativeValue %s into servings", (_description, recipeYield) => {
    const extracted = extractRecipeFromHTML(
      `<script type="application/ld+json">${recipeJSONLD(recipeYield)}</script>`
    );

    expect(extracted.structuredYield).toBeUndefined();
    expect(extracted.pageText).toContain("Recipe yield:");
  });

  it("does not read digits from a named fraction entity as a serving count", () => {
    expect(extractedYield("Makes &frac12; batch")).toBeUndefined();
  });
});

describe("microdata compatibility", () => {
  it("expands list-container properties and tag-specific values", () => {
    const html = `<h1>Vegetable stew</h1>
      <article itemscope itemtype="https://schema.org/Recipe">
        <h2 itemprop="name">Vegetable stew</h2>
        <data itemprop="recipeYield" value="4 servings"></data>
        <ul itemprop="recipeIngredient"><li>1 onion</li><li>2 carrots</li></ul>
        <ol itemprop="recipeInstructions"><li>Chop the vegetables.</li><li>Simmer until tender.</li></ol>
      </article>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({
      method: "microdata",
      title: "Vegetable stew",
      structuredYield: { servings: 4, label: "4 servings" },
      ingredients: ["1 onion", "2 carrots"],
      instructions: ["Chop the vegetables.", "Simmer until tender."]
    });
  });

  it("keeps all text from nested same-tag microdata containers", () => {
    const html = `<h1>Nested stew</h1><article itemscope itemtype="https://schema.org/Recipe">
      <div itemprop="name">Nested stew</div><meta itemprop="recipeYield" content="2 servings">
      <div itemprop="recipeIngredient"><div>1 onion</div><div>2 carrots</div></div>
      <div itemprop="recipeInstructions"><div>Chop everything.</div><div>Simmer.</div></div>
    </article>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({
      ingredients: ["1 onion", "2 carrots"],
      instructions: ["Chop everything.", "Simmer."]
    });
  });

  it("uses the page heading to keep a larger related microdata card from winning", () => {
    const html = `<h1>Main soup</h1>
      <article itemscope itemtype="https://schema.org/Recipe">
        <span itemprop="name">Main soup</span><meta itemprop="recipeYield" content="4 bowls">
        <span itemprop="recipeIngredient">1 onion</span><p itemprop="recipeInstructions">Simmer.</p>
      </article>
      <aside itemscope itemtype="https://schema.org/Recipe">
        <span itemprop="name">Related feast</span><meta itemprop="recipeYield" content="99 servings">
        <ul itemprop="recipeIngredient"><li>A</li><li>B</li><li>C</li></ul>
        <ol itemprop="recipeInstructions"><li>One.</li><li>Two.</li><li>Three.</li></ol>
      </aside>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({ title: "Main soup", structuredYield: { servings: 4 } });
  });

  it("keeps an outer main Recipe separate from a nested subrecipe", () => {
    const html = `<h1>Main rice bowl</h1>
      <article itemscope itemtype="https://schema.org/Recipe">
        <span itemprop="name">Main rice bowl</span><meta itemprop="recipeYield" content="4 bowls">
        <span itemprop="recipeIngredient">2 cups rice</span>
        <section itemprop="hasPart" itemscope itemtype="https://schema.org/Recipe">
          <span itemprop="name">Nested sauce</span><meta itemprop="recipeYield" content="99 jars">
          <span itemprop="recipeIngredient">1 chilli</span><p itemprop="recipeInstructions">Blend.</p>
        </section>
        <p itemprop="recipeInstructions">Cook the rice.</p>
      </article>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({
      title: "Main rice bowl",
      structuredYield: { servings: 4, label: "4 bowls" },
      ingredients: ["2 cups rice"],
      instructions: ["Cook the rice."]
    });
  });

  it("ignores commented microdata rather than importing its yield", () => {
    const decoy = `<article itemscope itemtype="https://schema.org/Recipe"><span itemprop="name">Decoy</span><meta itemprop="recipeYield" content="99"><span itemprop="recipeIngredient">Fake</span><p itemprop="recipeInstructions">Fake.</p></article>`;
    const html = `<!-- ${decoy} --><h1>Real soup</h1><article itemscope itemtype="https://schema.org/Recipe"><span itemprop="name">Real soup</span><meta itemprop="recipeYield" content="4"><span itemprop="recipeIngredient">Onion</span><p itemprop="recipeInstructions">Simmer.</p></article>`;
    expect(extractRecipeFromHTML(html)).toMatchObject({ title: "Real soup", structuredYield: { servings: 4 } });
  });
});

describe("HTML entity compatibility and fallback retention", () => {
  it("decodes common named, decimal, and hexadecimal HTML entities", () => {
    expect(cleanHTML("Tea&nbsp;&amp; cake: &#49; + &#x32; &lt; &#52;")).toBe("Tea & cake: 1 + 2 < 4");
  });

  it("does not crash on an invalid numeric HTML entity codepoint", () => {
    expect(() => cleanHTML("Recipe text &#x110000; continues safely.")).not.toThrow();
    expect(cleanHTML("Recipe text &#x110000; continues safely.")).toContain("continues safely.");
  });

  it("does not expose hidden template or comment text to model fallback", () => {
    const cleaned = cleanHTML(`<template><p>Serves 99</p></template><!-- Serves 88 --><main>${"Readable recipe article. ".repeat(8)}</main>`);
    expect(cleaned).not.toContain("Serves 99");
    expect(cleaned).not.toContain("Serves 88");
  });

  it("keeps serving evidence that appears late in visible page text in the model fallback prompt", () => {
    const navigation = "Navigation and article introduction. ".repeat(700);
    const html = `
      <article>${navigation}<p class="recipe-yield">Serves 8</p></article>
      <script type="application/ld+json">${recipeJSONLD(undefined)}</script>`;
    const extracted = extractRecipeFromHTML(html);
    expect(extracted.structuredYield).toBeUndefined();
    expect(extracted.pageText).toContain("Serves 8");

    const source: NormalizedRecipeSource = {
      sourceType: "url",
      sourceURL: "https://example.com/main-recipe",
      sourceTitle: extracted.title,
      ingredientsText: extracted.ingredients.join("\n"),
      instructionsText: extracted.instructions.join("\n"),
      pageText: extracted.pageText,
      images: [],
      locale: "en_GB",
      preferredUnitSystem: "metric"
    };
    expect(extractionPrompt(source)).toContain("Serves 8");
  });

  it("prioritizes an exact serving marker over many generic serve verbs", () => {
    const generic = Array.from({ length: 100 }, (_, index) => `${"x".repeat(500)} serve garnish ${index}`).join(" ");
    const midpoint = Math.floor(generic.length / 2);
    const pageText = `${generic.slice(0, midpoint)} Servings: 8 MAIN_SIGNAL ${generic.slice(midpoint)}`;
    const source: NormalizedRecipeSource = {
      sourceType: "url", pageText, images: [], locale: "en_GB", preferredUnitSystem: "metric"
    };
    expect(extractionPrompt(source)).toContain("Servings: 8 MAIN_SIGNAL");
  });

  it("rejects a readable-looking JavaScript client challenge instead of sending it to the model", () => {
    const challenge = `<title>Client Challenge</title><main>JavaScript is disabled in your browser. Please enable JavaScript to proceed. ${"A required part of this site could not load. ".repeat(8)}</main>`;
    expect(() => extractRecipeFromHTML(challenge)).toThrow(expect.objectContaining({ code: "source_blocked" }));
  });

  it("rejects a specific recipe URL that redirects to a generic recipe index", async () => {
    const request = new Request("https://worker.test/v1/recipe-imports", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sourceType: "url",
        url: "https://foodnetwork.example/recipes/chef/roast-turkey",
        locale: "en_GB",
        preferredUnitSystem: "metric",
        idempotencyKey: "generic-redirect"
      })
    });
    const fetcher = async (input: RequestInfo | URL) => {
      const url = new URL(input.toString());
      if (url.hostname === "foodnetwork.example") {
        return new Response(null, { status: 302, headers: { Location: "https://foodnetwork-index.example/recipes" } });
      }
      return new Response(`<main>${"Browse all of our popular recipe categories. ".repeat(8)}</main>`, { headers: { "Content-Type": "text/html" } });
    };
    await expect(prepareImportRequest(request, fetcher, async () => ["93.184.216.34"]))
      .rejects.toMatchObject({ code: "source_unavailable" });
  });

  it("shares the production generic-redirect classifier with the live compatibility harness", () => {
    expect(isGenericLandingRedirect(
      "https://foodnetwork.com/recipes/chef/roast-turkey",
      "https://foodnetwork.co.uk/recipes"
    )).toBe(true);
    expect(isGenericLandingRedirect(
      "https://www.example.com/recipes/roast-turkey/",
      "https://example.com/recipes/roast-turkey"
    )).toBe(false);
  });

  it("rejects a one-segment recipe redirect to a JSON-LD homepage", async () => {
    const request = new Request("https://worker.test/v1/recipe-imports", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sourceType: "url", url: "https://recipes.example/turkey", locale: "en_GB",
        preferredUnitSystem: "metric", idempotencyKey: "json-ld-homepage"
      })
    });
    const fetcher = async (input: RequestInfo | URL) => {
      const url = new URL(input.toString());
      if (url.pathname === "/turkey") return new Response(null, { status: 302, headers: { Location: "https://recipes.example/" } });
      return new Response(`<script type="application/ld+json">${recipeJSONLD("99 servings", { name: "Unrelated featured recipe" })}</script>`, {
        headers: { "Content-Type": "text/html" }
      });
    };
    await expect(prepareImportRequest(request, fetcher, async () => ["93.184.216.34"]))
      .rejects.toMatchObject({ code: "source_unavailable" });
  });
});

describe("model serving fallback reconciliation", () => {
  const source: NormalizedRecipeSource = {
    sourceType: "url",
    images: [],
    locale: "en_GB",
    preferredUnitSystem: "metric"
  };

  it("normalizes an empty model label as the missing-serving placeholder", () => {
    const recipe: Record<string, unknown> = {
      yield: { servings: 1, label: "   " },
      uncertainties: []
    };
    resolveRecipeServingCount(recipe, source);
    expect(recipe.yield).toEqual({ servings: 1, label: null });
    expect(recipe.uncertainties).toEqual([
      expect.objectContaining({ id: "missing-serving-count", message: missingServingCountMessage })
    ]);
  });

  it("preserves a genuine ambiguous-range serving warning", () => {
    const warning = {
      id: "ambiguous-serving-range",
      kind: "other",
      severity: "warning",
      message: "The serving count is unclear because the source says 4 to 6 servings.",
      ingredientIDs: [], stageIDs: [], sourceEvidence: "4 to 6 servings", isResolved: false
    };
    const recipe: Record<string, unknown> = {
      yield: { servings: 4, label: "4 to 6 servings" },
      uncertainties: [warning]
    };
    resolveRecipeServingCount(recipe, source);
    expect(recipe.uncertainties).toEqual([warning]);
  });
});
