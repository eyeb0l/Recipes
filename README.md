# Recipe Timeline

Recipe Timeline is a universal SwiftUI app for iOS and iPadOS 27. It turns a canonical recipe graph into an editorial cooking timeline: ingredients stay on the left, stages flow across the page, independent workstreams run in parallel, and merge stages span their inherited ingredient lineage. On iPhone the same graph is presented as focused step cards.

This repository contains the first vertical slice:

- SwiftData recipe library with a private CloudKit configuration, an automatic local fallback, search, sorting, and a continue-cooking shortcut.
- URL, pasted-text, photo-library, and document-camera import UI.
- Provider-neutral RecipeV1 JSON Schema with uncertainties instead of invented facts.
- Deterministic graph validation and timeline layout in the shared `RecipeCore` framework.
- Serving scaling, kitchen fractions, compatible metric/imperial conversion, and qualitative quantities.
- Per-recipe PDF, XLSX, and PNG export using the selected serving count and unit system.
- Prep checklist, structured editing, iPad drag/drop, and iPhone list reordering.
- Recoverable cook sessions that remember the chosen servings and units, dependency-ready focus, scaled "add now" amounts, concurrent timers, notifications, display-awake lifecycle, Live Activity, App Intent controls, and an explicit end-cooking action.
- A "kitchen notebook" design language with Liquid Glass controls, a scaled ingredient checklist, and estimated total time along the critical path.
- A privacy-preserving Cloudflare Worker with Sign in with Apple authentication, quotas, URL safety controls, layered page extraction, and an OpenAI Responses API extraction adapter using `gpt-6.1-terra`.

Substitutions and Reminders shopping lists are intentionally left for the next slice.

## Repository map

- `schema/recipe-v1.json` — provider-neutral canonical contract.
- `RecipeCore/` — models, migration, validation, units, layout, cook sessions, ActivityKit, and App Intents.
- `RecipesApp/` — adaptive SwiftUI app and SwiftData persistence.
- `RecipesWidget/` — cook-session Live Activity UI.
- `services/import-api/` — Hono/Cloudflare Worker and backend tests.
- `project.yml` — reproducible XcodeGen project definition.

## Build the app

Requirements: Xcode 27, Swift 6.4, XcodeGen 2.44 or later, and an iOS/iPadOS 27-or-newer deployment device.

```sh
xcodegen generate
xcodebuild -project RecipeTimeline.xcodeproj \
  -scheme RecipeTimeline \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Device and TestFlight builds use Apple Developer team `359794K46A`, the app identifier `com.irisgiertuga.RecipeTimeline`, and matching App Group and iCloud identifiers declared in `project.yml`. Regenerate the project after changing these values. `Configs/Signing.xcconfig.example` records the coordinated identifier set; it is not loaded automatically, so it cannot silently override generated target identifiers.

The app uses the deployed import endpoint at `https://recipe-timeline-import-api.iris-account.workers.dev`. Change `IMPORT_API_BASE_URL` in `project.yml` if the Worker hostname changes, then regenerate the Xcode project before archiving.

## Run backend checks

```sh
cd services/import-api
pnpm install
pnpm typecheck
pnpm test
pnpm exec wrangler deploy --dry-run
```

The live contract calls the configured OpenAI model and never substitutes another:

```sh
pnpm test:live:openai
```

The script loads secrets from the git-ignored `.dev.vars` and prints only provider/model and validation counts. See `services/import-api/README.md` for provisioning and deployment.

## Data boundaries

Canonical recipes and cleaned source text are stored by the app. Cookbook images are normalized on device, uploaded only for the extraction request, and never inserted into SwiftData. Active cooking state is stored separately in the App Group so Live Activity intents do not write cook progress into CloudKit. The Worker stores only opaque session material, token hashes, and quota counters; request bodies and canonical results are not logged or retained.

## Verification notes

The project can compile all app, framework, Live Activity, unit-test, and UI-test bundles without signing using a generic iOS Simulator destination. Running XCTest and UI snapshots still requires a working simulator or physical signing setup. Backend tests are local and do not require provider credentials; live provider scripts do.
