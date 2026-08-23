import { APIError } from "../src/errors";
import { extractRecipeFromHTML } from "../src/extraction/html-recipe";
import { fetchPublicRecipe, type Fetcher } from "../src/extraction/public-fetch";
import { isGenericLandingRedirect } from "../src/import-request";

const overallTimeoutMilliseconds = 20_000;
const productionAcceptHeader = "text/html,application/ld+json,application/json;q=0.8";

interface CompatibilityResult {
  url: string;
  status: number | null;
  finalURL: string | null;
  contentType: string | null;
  title: string | null;
  method: "json-ld" | "microdata" | "cleaned-prose" | null;
  structuredYield: { servings: number; label: string | null } | null;
  ingredientCount: number | null;
  instructionCount: number | null;
  pageTextPresent: boolean | null;
  error: string | null;
}

async function checkRecipeSite(sourceURL: string): Promise<CompatibilityResult> {
  const result: CompatibilityResult = {
    url: sourceURL,
    status: null,
    finalURL: null,
    contentType: null,
    title: null,
    method: null,
    structuredYield: null,
    ingredientCount: null,
    instructionCount: null,
    pageTextPresent: null,
    error: null
  };

  const overallController = new AbortController();
  const timeout = setTimeout(() => overallController.abort(new Error("compatibility check timeout")), overallTimeoutMilliseconds);
  const observingFetcher: Fetcher = async (input, init) => {
    const headers = new Headers(init?.headers);
    const isRecipePageRequest = headers.get("Accept") === productionAcceptHeader;
    if (isRecipePageRequest) result.finalURL = requestURL(input);

    const response = await fetch(input, {
      ...init,
      signal: combineAbortSignals(overallController.signal, init?.signal)
    });
    if (isRecipePageRequest) {
      result.status = response.status;
      result.finalURL = response.url || result.finalURL;
      result.contentType = normalizedContentType(response.headers.get("Content-Type"));
    }
    return response;
  };

  try {
    const page = await fetchPublicRecipe(sourceURL, observingFetcher);
    result.finalURL = page.finalURL;
    result.contentType = page.contentType || result.contentType;
    if (isGenericLandingRedirect(sourceURL, page.finalURL)) {
      throw new APIError(422, "source_unavailable", "The recipe page redirected to a general site page. Paste its recipe text or scan the page instead.");
    }

    const extracted = extractRecipeFromHTML(page.body);
    result.title = extracted.title ?? null;
    result.method = extracted.method;
    result.structuredYield = extracted.structuredYield ?? null;
    result.ingredientCount = extracted.ingredients.length;
    result.instructionCount = extracted.instructions.length;
    result.pageTextPresent = Boolean(extracted.pageText?.trim());
  } catch (error) {
    result.error = overallController.signal.aborted
      ? `timed_out: Compatibility check exceeded ${overallTimeoutMilliseconds} ms.`
      : describeError(error);
  } finally {
    clearTimeout(timeout);
  }

  return result;
}

function combineAbortSignals(overall: AbortSignal, request: AbortSignal | null | undefined): AbortSignal {
  if (!request) return overall;
  if (overall.aborted) return overall;
  if (request.aborted) return request;
  return AbortSignal.any([overall, request]);
}

function requestURL(input: RequestInfo | URL): string {
  if (input instanceof Request) return input.url;
  return input.toString();
}

function normalizedContentType(value: string | null): string | null {
  const contentType = (value ?? "").split(";", 1)[0]?.trim().toLowerCase() ?? "";
  return contentType || null;
}

function describeError(error: unknown): string {
  if (error instanceof APIError) return `${error.code}: ${error.message}`;
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return `unknown_error: ${String(error)}`;
}

const sourceURLs = process.argv.slice(2).filter((argument: string) => argument !== "--");
if (sourceURLs.length === 0) {
  process.stderr.write("Usage: node --import tsx scripts/recipe-site-compat.ts <url> [url ...]\n");
  process.exitCode = 2;
} else {
  for (const sourceURL of sourceURLs) {
    const result = await checkRecipeSite(sourceURL);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  }
}
