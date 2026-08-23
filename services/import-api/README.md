# Recipe import Worker

This Hono Worker accepts one URL, one pasted recipe, or one-to-four cookbook images and returns a schema-valid RecipeV1 document. Provider/model selection is deployment configuration, never a client choice.

## Local setup

```sh
pnpm install
cp .dev.vars.example .dev.vars
pnpm dev
```

Set a random `SESSION_SIGNING_KEY` of at least 32 bytes and the key for the configured provider. `.dev.vars`, source text, images, URLs, provider payloads, and canonical recipes must never be committed or logged.

The default provider is OpenAI with model ID `gpt-5.6-luna`. If account discovery or structured output fails, the request fails; it does not fall back to Grok. Set `RECIPE_PROVIDER=grok` only when explicitly testing the Grok adapter with `grok-4.6`.

## Cloudflare provisioning

1. Create production and preview KV namespaces for `SESSIONS` and replace the placeholder IDs in `wrangler.jsonc`.
2. Configure the Sign in with Apple service/app identifier as `APPLE_CLIENT_ID`.
3. Add `SESSION_SIGNING_KEY` and the active provider key with `wrangler secret put`. Keep provider keys out of `vars` and out of the app.
4. Confirm the per-minute rate binding and the 20-import UTC daily quota suit the private TestFlight group.
5. Run `pnpm typecheck`, `pnpm test`, and `pnpm exec wrangler deploy --dry-run` before `pnpm deploy`.

## Request flow

- `/v1/session/apple` verifies Apple’s signed identity token and issues a 15-minute access token plus a rotating 30-day refresh token.
- `/v1/session/refresh` consumes the prior hashed refresh token and rotates the session.
- `/v1/recipe-imports` authenticates, applies per-user rate/daily quota controls, normalizes the source, calls exactly one configured provider, validates the strict JSON Schema and graph invariants, and returns the result with provider metadata.
- `/health` exposes only service and schema status.

URL imports reject credentials, non-HTTP protocols, local/private/link-local/reserved IPs, unsafe DNS answers, unsafe redirect targets, excessive redirects, unsupported content types, large bodies, and timeouts. Structured Recipe JSON-LD is preferred, then Recipe microdata, then cleaned prose. The service does not bypass blocked sites.

For serving counts, an unambiguous structured `recipeYield` is authoritative and is reconciled after model extraction. If structured data does not establish a count, readable page text is included for model extraction. Only the model's explicit `1`/`null` missing-yield fallback becomes a placeholder serving with a plain-language warning.

Concurrent retries with the same user/idempotency key share only an in-flight promise. It is deleted immediately after completion, preserving the no-result-retention boundary.

## Provider contracts

Both adapters receive the same schema and prompt rules. The OpenAI adapter uses the Responses API with strict JSON Schema output, image input when present, and `store: false`. The Grok adapter uses xAI’s strict JSON Schema response format. Backend validation rejects missing fields, extra properties, dangling references, cycles, and unused ingredients not covered by an uncertainty.
