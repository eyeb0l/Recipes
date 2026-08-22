import { describe, expect, it } from "vitest";
import { validateCanonicalRecipe } from "../src/canonical";
import { validRecipe } from "./fixtures";

describe("canonical recipe validation", () => {
  it("accepts a coherent acyclic recipe", () => {
    expect(() => validateCanonicalRecipe(validRecipe())).not.toThrow();
  });

  it("rejects sub-unit serving counts", () => {
    const recipe = validRecipe();
    recipe.yield.servings = 0.004;
    expect(() => validateCanonicalRecipe(recipe)).toThrow(/RecipeV1/u);
  });

  it("enforces required fields and rejects additional properties", () => {
    const missing = validRecipe();
    delete missing.stages[0].instruction;
    expect(() => validateCanonicalRecipe(missing)).toThrow(/RecipeV1/u);

    const additional = validRecipe();
    additional.modelThoughts = "not part of the provider-neutral contract";
    expect(() => validateCanonicalRecipe(additional)).toThrow(/RecipeV1/u);
  });

  it("rejects dangling ingredient references", () => {
    const recipe = validRecipe();
    recipe.stages[0]!.ingredientUses[0]!.ingredientID = "missing";
    expect(() => validateCanonicalRecipe(recipe)).toThrow(/dangling stage ingredient/u);
  });

  it("rejects dependency cycles", () => {
    const recipe = validRecipe();
    recipe.stages.push({ ...recipe.stages[0]!, id: "cook", dependencies: ["mix"], ingredientUses: [] });
    recipe.stages[0]!.dependencies = ["cook"];
    expect(() => validateCanonicalRecipe(recipe)).toThrow(/cyclic/u);
  });

  it("requires an uncertainty for every unused ingredient", () => {
    const recipe = validRecipe();
    recipe.ingredients.push({ ...recipe.ingredients[0]!, id: "salt", name: "salt", sortIndex: 1 });
    expect(() => validateCanonicalRecipe(recipe)).toThrow(/unused/u);
    recipe.uncertainties.push({
      id: "salt-placement", kind: "missingPlacement", severity: "warning", message: "The source does not say when to add salt.",
      ingredientIDs: ["salt"], stageIDs: [], sourceEvidence: null, isResolved: false
    });
    expect(() => validateCanonicalRecipe(recipe)).not.toThrow();
  });
});
