# Recipe Timeline

Recipe Timeline is a universal SwiftUI app for iOS and iPadOS 26. It turns a canonical recipe graph into an editorial cooking timeline: ingredients stay on the left, stages flow across the page, independent workstreams run in parallel, and merge stages span their inherited ingredient lineage. On iPhone the same graph is presented as focused step cards.

This repository contains the first vertical slice:

- SwiftData recipe library with a private CloudKit configuration and an automatic local fallback.
- URL, pasted-text, photo-library, and document-camera import UI.
- Provider-neutral RecipeV1 JSON Schema with uncertainties instead of invented facts.
- Deterministic graph validation and timeline layout in the shared `RecipeCore` framework.
- Serving scaling, kitchen fractions, compatible metric/imperial conversion, and qualitative quantities.
- Prep checklist, structured editing, iPad drag/drop, and iPhone list reordering.
- Recoverable cook sessions, dependency-ready focus, concurrent timers, notifications, display-awake lifecycle, Live Activity, and App Intent controls.
- A privacy-preserving Cloudflare Worker with Sign in with Apple authentication, quotas, URL safety controls, layered page extraction, and Grok/OpenAI adapters.

Substitutions, Reminders shopping lists, and PNG/PDF/XLSX export are intentionally left for the next slice.

## Repository map

- `schema/recipe-v1.json` — provider-neutral canonical contract.
- `RecipeCore/` — models, migration, validation, units, layout, cook sessions, ActivityKit, and App Intents.
- `RecipesApp/` — adaptive SwiftUI app and SwiftData persistence.
- `RecipesWidget/` — cook-session Live Activity UI.
- `services/import-api/` — Hono/Cloudflare Worker and backend tests.
- `project.yml` — reproducible XcodeGen project definition.

## Build the app

Requirements: Xcode 27, Swift 6.4, XcodeGen 2.44 or later, and an iOS/iPadOS 26-or-newer deployment device.

```sh
xcodegen generate
xcodebuild -project RecipeTimeline.xcodeproj \
  -scheme RecipeTimeline \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Before device or TestFlight builds, replace the `com.example` bundle, App Group, and iCloud identifiers in `project.yml`, set your Apple development team, regenerate the project, and create matching capabilities in the Apple Developer portal. `Configs/Signing.xcconfig.example` records the values that must be supplied; it is not loaded automatically so a local signing file cannot silently override generated target identifiers.

The default import endpoint is `http://127.0.0.1:8787`. Change `IMPORT_API_BASE_URL` in `project.yml` to the deployed HTTPS Worker URL before an archive.

## Run backend checks

```sh
cd services/import-api
pnpm install
pnpm typecheck
pnpm test
pnpm exec wrangler deploy --dry-run
```

Live contracts never substitute providers:

```sh
pnpm test:live:grok
pnpm test:live:openai
```

The scripts load secrets from the git-ignored `.dev.vars` and print only provider/model and validation counts. See `services/import-api/README.md` for provisioning and deployment.

## Data boundaries

Canonical recipes and cleaned source text are stored by the app. Cookbook images are normalized on device, uploaded only for the extraction request, and never inserted into SwiftData. Active cooking state is stored separately in the App Group so Live Activity intents do not write cook progress into CloudKit. The Worker stores only opaque session material, token hashes, and quota counters; request bodies and canonical results are not logged or retained.

## Verification notes

The project can compile all app, framework, Live Activity, unit-test, and UI-test bundles without signing using a generic iOS Simulator destination. Running XCTest and UI snapshots still requires a working simulator or physical signing setup. Backend tests are local and do not require provider credentials; live provider scripts do.
