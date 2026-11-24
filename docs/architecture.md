# Architecture decisions

## Canonical data before presentation

`RecipeV1` contains ingredient identities, quantities, prep tasks, workstreams, dependency edges, ingredient allocations, intermediate results, timings, heat, temperatures, provenance, and linked uncertainties. It deliberately contains no rows, columns, or chart spans.

`TimelineLayoutEngine` validates the graph, assigns topological depth to columns, derives transitive ingredient lineage through dependencies, allocates stable subcolumns only for row collisions, emits ingredient-free stages as instruction bands, and spans merge stages over the union of incoming lineages. SwiftUI consumes these placements while `Canvas` draws non-interactive grid lines.

## Persistence boundary

Each `RecipeRecord` stores versioned canonical JSON plus searchable metadata and cleaned provenance text. `RecipeSchemaMigrator` upgrades older preview JSON before decoding. The primary SwiftData configuration uses the private iCloud database and falls back to a local store if CloudKit initialization fails.

`CookSessionStore` is a separate actor-backed JSON store in the App Group. This prevents timer ticks, stage completion, and Live Activity intent actions from becoming CloudKit merge conflicts.

## Units

`RecipeV1` unit IDs name one measure each, so they can be converted exactly. `cup`, `fluidOunce` and `pint` are US measures; `imperialFluidOunce` and `imperialPint` are UK ones, shown as "UK fl oz" and "UK pint". New unit IDs are added within schema version 1 because the document's shape doesn't change, and recipes saved with `pint` keep meaning US pints. Bumping the version would make every recipe unreadable to older builds, not just the ones that use a new unit.

A build that predates a unit can't decode a recipe that uses it. The import service rewrites such units for those builds (see the [import service README](../services/import-api/README.md)), but a recipe saved by a newer build and synced through iCloud won't open on a device still running an older build until that device updates.

## Cook state

A stage is ready when it is incomplete and all dependency IDs are complete. Multiple ready stages can run in parallel; one is focused. Timers are independent persisted records with absolute end dates, so reconciliation after termination is deterministic. One Live Activity summarizes the whole session and points back through `recipetimeline://cook?session=…`.

## Substitutions and shopping lists

`IngredientSubstitutions` is a curated, offline catalogue in RecipeCore. Rules match ingredient names by whole words (allowing plurals), skip look-alikes through excluded words ("peanut" in "peanut butter"), and the longest matching phrase wins across rules. Each component's amount is either a share of the original amount, set per dimension so a ratio that makes no sense for counted items yields no amount, or a fixed amount per reference quantity for swaps that change units, such as one tablespoon of ground flaxseed per egg. Amounts are scaled and converted like the recipe's own quantities. Substitutes are guidance only; they never change the canonical recipe.

`ShoppingList` turns a recipe into items to buy at the chosen servings, combining ingredients with the same name and adding up their amounts when the units allow. `ShoppingList.plan` merges those items into a Reminders list without duplicates: each item is a reminder titled with the ingredient, so Reminders' grocery lists can sort it into sections, and the amount and recipe go on their own line in its notes. An incomplete reminder with the same name is reused, and adding a recipe again replaces its line instead of adding another. The app writes the plan through `ShoppingReminderStore`, backed by EventKit, with an in-memory store for tests and `--ui-testing` launches.

## Generated recipes

The import service can also write a recipe from a description, using web search, and revise it at the cook's feedback. Drafts live only in the create sheet until the cook saves one: each revision sends the current draft, the feedback, and the earlier feedback and sources back to the stateless Worker, which returns a whole new draft. The sheet keeps earlier drafts so a change can be undone. A saved recipe has the `generated` source type, and its source text records the request, the changes asked for and the pages consulted.

`generated` is a new `RecipeSourceType` within schema version 1, like the UK units, so a generated recipe synced through iCloud won't open on a build that predates it until that device updates.

## Import trust boundary

The app never contains provider secrets. It authenticates to the Worker with Sign in with Apple, then submits one normalized source. URL fetching and provider invocation occur only in the Worker. The model returns canonical data; the backend and app independently validate graph references and cycles before deterministic rendering.

## Data boundaries

Canonical recipes and cleaned source text are stored by the app. Cookbook images are normalized on device, uploaded only for the extraction request, and never inserted into SwiftData. Active cooking state is stored separately in the App Group so Live Activity intents do not write cook progress into CloudKit. Shopping lists go to Reminders on the device through EventKit, with full Reminders access because the app reads the chosen list to avoid duplicates. Substitution lookups never leave the device. Recipe requests, feedback and drafts are sent to the Worker only for the generation call, and are neither logged nor kept there. The Worker stores only opaque session material, token hashes, and quota counters; request bodies and canonical results are not logged or retained.
