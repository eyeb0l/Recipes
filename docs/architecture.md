# Architecture decisions

## Canonical data before presentation

`RecipeV1` contains ingredient identities, quantities, prep tasks, workstreams, dependency edges, ingredient allocations, intermediate results, timings, heat, temperatures, provenance, and linked uncertainties. It deliberately contains no rows, columns, or chart spans.

`TimelineLayoutEngine` validates the graph, assigns topological depth to columns, derives transitive ingredient lineage through dependencies, allocates stable subcolumns only for row collisions, emits ingredient-free stages as instruction bands, and spans merge stages over the union of incoming lineages. SwiftUI consumes these placements while `Canvas` draws non-interactive grid lines.

## Persistence boundary

Each `RecipeRecord` stores versioned canonical JSON plus searchable metadata and cleaned provenance text. `RecipeSchemaMigrator` upgrades older preview JSON before decoding. The primary SwiftData configuration uses the private iCloud database and falls back to a local store if CloudKit initialization fails.

`CookSessionStore` is a separate actor-backed JSON store in the App Group. This prevents timer ticks, stage completion, and Live Activity intent actions from becoming CloudKit merge conflicts.

## Cook state

A stage is ready when it is incomplete and all dependency IDs are complete. Multiple ready stages can run in parallel; one is focused. Timers are independent persisted records with absolute end dates, so reconciliation after termination is deterministic. One Live Activity summarizes the whole session and points back through `recipetimeline://cook?session=…`.

## Import trust boundary

The app never contains provider secrets. It authenticates to the Worker with Sign in with Apple, then submits one normalized source. URL fetching and provider invocation occur only in the Worker. The model returns canonical data; the backend and app independently validate graph references and cycles before deterministic rendering.
