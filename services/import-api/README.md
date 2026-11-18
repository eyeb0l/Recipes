# Recipe import Worker

This Hono Worker accepts one URL, one pasted recipe, or one-to-four cookbook images and returns a schema-valid RecipeV1 document. Provider/model selection is deployment configuration, never a client choice.

## Local setup

```sh
pnpm install
cp .dev.vars.example .dev.vars
pnpm dev
```

Set a random `SESSION_SIGNING_KEY` of at least 32 bytes and `OPENAI_API_KEY`. `.dev.vars`, source text, images, URLs, provider payloads, and canonical recipes must never be committed or logged.

The only provider is OpenAI. The default model is `gpt-6.1-terra`, OpenAI's fast, vision-capable GPT-6.1 model, called through the Responses API with low reasoning effort. Set `OPENAI_MODEL` to use another OpenAI model that supports image input and Structured Outputs (for example `gpt-6-luna` for lower cost, or `gpt-6.1-sol` for harder sources). If extraction fails, the request fails; there is no fallback model.

## Cloudflare provisioning

1. Create production and preview KV namespaces for `SESSIONS` and replace the placeholder IDs in `wrangler.jsonc`.
2. Configure the Sign in with Apple service/app identifier as `APPLE_CLIENT_ID`.
3. Add `SESSION_SIGNING_KEY` and `OPENAI_API_KEY` with `wrangler secret put`. Keep provider keys out of `vars` and out of the app. Deployments that previously used Grok can remove the unused `XAI_API_KEY` secret with `wrangler secret delete XAI_API_KEY`.
4. Confirm the per-minute rate binding and the 20-import UTC daily quota suit the private TestFlight group.
5. Run `pnpm typecheck`, `pnpm test`, and `pnpm exec wrangler deploy --dry-run` before `pnpm run deploy`.

## Request flow

- `/v1/session/apple` verifies Apple’s signed identity token and issues a 15-minute access token plus a rotating 30-day refresh token.
- `/v1/session/refresh` consumes the prior hashed refresh token and rotates the session.
- `/v1/recipe-imports` authenticates, applies the per-user rate limit, normalizes and validates the source, spends one unit of the daily quota only when new extraction work starts (invalid sources and retries that join in-flight work are free), calls OpenAI, validates the strict JSON Schema and graph invariants, and returns the result with provider metadata.
- `/health` exposes only service and schema status.

URL imports reject credentials, non-HTTP protocols, local/private/link-local/reserved IPs, unsafe DNS answers, unsafe redirect targets, excessive redirects, unsupported content types, large bodies, and timeouts. Structured Recipe JSON-LD is preferred, then Recipe microdata, then cleaned prose. The service does not bypass blocked sites.

For serving counts, an unambiguous structured `recipeYield` is authoritative and is reconciled after model extraction. If structured data does not establish a count, readable page text is included for model extraction. Only the model's explicit `1`/`null` missing-yield fallback becomes a placeholder serving with a plain-language warning.

Pints and fluid ounces come in US (`pint`, `fluidOunce`) and UK imperial (`imperialPint`, `imperialFluidOunce`) sizes. The model chooses from the source alone: the quantity's own wording, then a metric equivalent beside it, then the rest of the recipe and the page's declared language, never the user's locale. When the source doesn't settle it, the model keeps the US unit and adds an `ambiguousQuantity` warning. After extraction, a quantity's own wording overrides the model: "UK pint" or "US pint", or a single metric equivalent within 8% of one pint size, such as "½ pint (300 ml)". A stage allocation with no such wording follows its ingredient.

Import requests list the RecipeV1 units the app can decode in `supportedUnits`. App builds released before the UK units don't send it, so they receive UK amounts as whole millilitres, with `originalText` unchanged, instead of a recipe they can't decode.

## Live publisher compatibility

Run the production fetch and parser path against public recipe URLs with:

```sh
pnpm run test:live:sites -- https://example.com/recipe [https://example.org/another-recipe ...]
```

The harness uses the Worker's real User-Agent, DNS and redirect checks, timeouts, response-size limit, and layered extractor. It emits one JSON record per URL and never runs publisher JavaScript. Treat origin `402`/`403` responses and client challenges as access limitations; do not spoof a browser to bypass them. Keep distilled regression fixtures in the unit suite because live pages can change independently of the Worker.

Concurrent retries with the same user/idempotency key share only an in-flight promise. It is deleted immediately after completion, preserving the no-result-retention boundary.

## Provider contract

The OpenAI adapter uses the Responses API with strict JSON Schema output (`text.format`), image input when present, low reasoning effort, a 24,000-token output budget, and `store: false`. Truncated (`incomplete`) responses and refusals are reported as distinct, user-readable errors rather than malformed JSON. Backend validation rejects missing fields, extra properties, dangling references, cycles, and unused ingredients not covered by an uncertainty.
