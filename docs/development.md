# Development guide

## Repository map

- `schema/recipe-v1.json` — provider-neutral canonical RecipeV1 contract, with uncertainties instead of invented facts.
- `RecipeCore/` — models, migration, graph validation, units and scaling, timeline layout, cook sessions, ActivityKit, and App Intents.
- `RecipesApp/` — adaptive SwiftUI app and SwiftData persistence.
- `RecipesWidget/` — cook-session Live Activity UI.
- `services/import-api/` — Hono/Cloudflare Worker that turns a URL, pasted text, or cookbook images into a RecipeV1 document, and its tests.
- `project.yml` — reproducible XcodeGen project definition.

See [Architecture](architecture.md) for how these pieces fit together.

## Build the app

Requirements: Xcode 27, Swift 6.4, XcodeGen 2.44 or later, and an iOS/iPadOS 27-or-newer deployment device.

```sh
xcodegen generate
xcodebuild -project RecipeTimeline.xcodeproj \
  -scheme RecipeTimeline \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

`RecipeTimeline.xcodeproj` is committed and generated from `project.yml`. Edit `project.yml`, run `xcodegen generate`, and commit both; CI fails if they drift apart.

### Signing and identifiers

Device and TestFlight builds use Apple Developer team `359794K46A`, the app identifier `com.irisgiertuga.RecipeTimeline`, and matching App Group and iCloud identifiers declared in `project.yml`. Regenerate the project after changing these values. `Configs/Signing.xcconfig.example` records the coordinated identifier set; it is not loaded automatically, so it cannot silently override generated target identifiers.

### Import endpoint

The app uses the deployed import endpoint at `https://recipe-timeline-import-api.iris-account.workers.dev`. Change `IMPORT_API_BASE_URL` in `project.yml` if the Worker hostname changes, then regenerate the Xcode project before archiving.

## Run the app tests

```sh
xcodebuild test \
  -project RecipeTimeline.xcodeproj \
  -scheme RecipeTimeline \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  CODE_SIGNING_ALLOWED=NO
```

Add `-only-testing:RecipeCoreTests -only-testing:RecipeTimelineTests` to run only the unit tests, as CI does. Unit tests run inside the app with an in-memory library that never touches CloudKit. UI tests launch the app with `--ui-testing`, which seeds the Espresso Brownies sample recipe.

The project compiles all app, framework, Live Activity, unit-test, and UI-test bundles without signing. Running tests needs a simulator; physical devices need a signing setup.

### README screenshots

The screenshots in `docs/images/` come from the snapshot UI tests (`testEditorialTimelineSnapshot`, `testRecipeDetailSnapshots`, and `testDarkCookModeSnapshot`), run on an iPad Pro 13-inch and an iPhone 18 Pro simulator. The cook-mode test launches the app with `--ui-testing-dark`, so that screenshot is in dark mode. Uninstall the app from the simulator first so a cook session from a previous run doesn't show up, then export the attachments from the result bundle:

```sh
xcrun xcresulttool export attachments --path TestResults.xcresult --output-path screenshots
```

Landscape iPad screenshots are exported in portrait orientation; rotate them with `sips -r 270`.

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

The script loads secrets from the git-ignored `.dev.vars` and prints only provider/model and validation counts. Backend unit tests are local and need no provider credentials; the live scripts do. See the [import service README](../services/import-api/README.md) for provisioning and deployment.

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every pull request and on pushes to `main`:

- **Import API** (Ubuntu): `pnpm install --frozen-lockfile`, type checking, the Vitest suite, and a Wrangler dry-run build.
- **iOS app** (`xcode-27` runner, Xcode 27.2): checks that the committed Xcode project matches `project.yml`, builds the app, Live Activity, and all test bundles without signing, and runs the unit tests on an iPhone 18 Pro simulator. The result bundle is uploaded when tests fail.

UI tests are not run in CI; run them locally before changing layout or cook-mode flows.

`main` is protected: changes land through pull requests, both CI checks must pass on an up-to-date branch, and force pushes and branch deletion are blocked.
