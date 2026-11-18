import { describe, expect, it } from "vitest";
import { validateCanonicalRecipe } from "../src/canonical";
import { adaptRecipeUnitsForClient, legacyUnitIDs, reconcileSystemDependentUnits } from "../src/unit-resolution";
import recipeSchema from "../../../schema/recipe-v1.json";
import { validRecipe } from "./fixtures";

function quantity(value: number, unit: string, originalText: string | null): any {
  return { kind: "exact", value, lower: null, upper: null, text: null, unit, originalText };
}

function recipeWithMilk(milk: any, use: any = null): any {
  const recipe = validRecipe();
  recipe.ingredients.push({ id: "milk", name: "milk", quantity: milk, scalable: true, notes: null, sortIndex: 1 });
  recipe.stages[0].ingredientUses.push({ ingredientID: "milk", quantity: use, stateChange: null });
  return recipe;
}

describe("US and UK pints and fluid ounces", () => {
  it("adds the UK units to the schema without changing the schema version", () => {
    const units = (recipeSchema as any).$defs.unitID.enum as string[];
    expect(units).toEqual(expect.arrayContaining(["pint", "fluidOunce", "imperialPint", "imperialFluidOunce"]));
    expect(units.filter((unit) => !legacyUnitIDs.includes(unit))).toEqual(["imperialFluidOunce", "imperialPint"]);
    expect((recipeSchema as any).properties.schemaVersion.const).toBe(1);

    const recipe = recipeWithMilk(quantity(1, "imperialPint", "1 pint"), quantity(20, "imperialFluidOunce", null));
    expect(() => validateCanonicalRecipe(recipe)).not.toThrow();
    recipe.ingredients[1].quantity.unit = "britishPint";
    expect(() => validateCanonicalRecipe(recipe)).toThrow(/RecipeV1/u);
  });

  it.each([
    ["1 UK pint milk", "pint", "imperialPint"],
    ["1 imperial pint milk", "pint", "imperialPint"],
    ["1 British pint of milk", "pint", "imperialPint"],
    ["1 pint (UK) milk", "pint", "imperialPint"],
    ["1 US pint milk", "imperialPint", "pint"],
    ["1 American pint milk", "imperialPint", "pint"]
  ])("follows an explicit label in %j", (originalText, modelUnit, expected) => {
    const recipe = recipeWithMilk(quantity(1, modelUnit, originalText));
    reconcileSystemDependentUnits(recipe);
    expect(recipe.ingredients[1].quantity.unit).toBe(expected);
  });

  it.each([
    ["1/2 pint (300 ml) double cream", 0.5, "pint", "imperialPint"],
    ["1 pint (568ml) milk", 1, "pint", "imperialPint"],
    ["1 pint (600ml) milk", 1, "pint", "imperialPint"],
    ["2 pints (1.2 litres) stock", 2, "pint", "imperialPint"],
    ["1¾ pints (1 litre) water", 1.75, "pint", "imperialPint"],
    ["1 pint (475 ml) milk", 1, "imperialPint", "pint"],
    ["1 pint (500 ml) milk", 1, "imperialPint", "pint"],
    ["½ pint (240 ml) cream", 0.5, "imperialPint", "pint"]
  ])("follows a metric equivalent in %j", (originalText, value, modelUnit, expected) => {
    const recipe = recipeWithMilk(quantity(value, modelUnit, originalText));
    reconcileSystemDependentUnits(recipe);
    expect(recipe.ingredients[1].quantity.unit).toBe(expected);
  });

  it.each([
    ["1 pint milk", "pint"],
    ["1 pint milk", "imperialPint"],
    ["1 pint (about 520 ml) milk", "pint"],
    ["1 pint (568 ml) or 500 ml milk", "pint"],
    ["1 UK pint (1.2 US pints) milk", "pint"],
    ["10 fl oz (300 ml) milk", "fluidOunce"],
    ["10 fl oz (300 ml) milk", "imperialFluidOunce"]
  ])("keeps the model's choice when %j doesn't settle it", (originalText, modelUnit) => {
    const recipe = recipeWithMilk(quantity(originalText.startsWith("10") ? 10 : 1, modelUnit, originalText));
    const uncertainties = [{
      id: "pint-size", kind: "ambiguousQuantity", severity: "warning",
      message: "The recipe doesn't say whether the milk is in UK pints (568 ml) or US pints (473 ml).",
      ingredientIDs: ["milk"], stageIDs: [], sourceEvidence: null, isResolved: false
    }];
    recipe.uncertainties = structuredClone(uncertainties);
    reconcileSystemDependentUnits(recipe);
    expect(recipe.ingredients[1].quantity.unit).toBe(modelUnit);
    expect(recipe.uncertainties).toEqual(uncertainties);
  });

  it("follows labelled fluid ounces but not their metric equivalents", () => {
    const recipe = recipeWithMilk(quantity(10, "fluidOunce", "10 UK fl oz milk"));
    reconcileSystemDependentUnits(recipe);
    expect(recipe.ingredients[1].quantity.unit).toBe("imperialFluidOunce");
  });

  it("makes a stage allocation without its own evidence use its ingredient's system", () => {
    const recipe = recipeWithMilk(quantity(1, "pint", "1 pint (570 ml) milk"), quantity(10, "fluidOunce", "10 fl oz"));
    recipe.ingredients.push({ id: "cream", name: "cream", quantity: quantity(1, "imperialPint", "1 pint cream"), scalable: true, notes: null, sortIndex: 2 });
    recipe.stages[0].ingredientUses.push(
      { ingredientID: "cream", quantity: quantity(0.5, "pint", null), stateChange: null },
      { ingredientID: "cream", quantity: quantity(10, "fluidOunce", "10 US fl oz"), stateChange: null }
    );
    reconcileSystemDependentUnits(recipe);
    const uses = recipe.stages[0].ingredientUses;
    expect(recipe.ingredients[1].quantity.unit).toBe("imperialPint");
    expect(uses[1].quantity.unit).toBe("imperialFluidOunce");
    expect(uses[2].quantity.unit).toBe("imperialPint");
    // An allocation that says which it means keeps it.
    expect(uses[3].quantity.unit).toBe("fluidOunce");
  });

  it("leaves other units alone", () => {
    const recipe = recipeWithMilk(quantity(300, "milliliter", "1/2 pint (300 ml) milk"), quantity(1, "cup", "1 UK cup"));
    const before = structuredClone(recipe);
    reconcileSystemDependentUnits(recipe);
    expect(recipe).toEqual(before);
  });
});

describe("units for app builds without UK pints", () => {
  it("rewrites UK units as millilitres for builds that don't list their units", () => {
    const recipe = recipeWithMilk(quantity(1, "imperialPint", "1 pint"), quantity(0.25, "imperialFluidOunce", "1/4 fl oz"));
    recipe.ingredients.push({
      id: "stock", name: "stock",
      quantity: { kind: "range", value: null, lower: 1, upper: 2, text: null, unit: "imperialPint", originalText: "1-2 pints" },
      scalable: true, notes: null, sortIndex: 2
    });
    recipe.stages[0].ingredientUses.push({ ingredientID: "stock", quantity: null, stateChange: null });
    reconcileSystemDependentUnits(recipe);
    adaptRecipeUnitsForClient(recipe, undefined);

    expect(recipe.ingredients[1].quantity).toEqual(quantity(568, "milliliter", "1 pint"));
    expect(recipe.stages[0].ingredientUses[1].quantity).toEqual(quantity(7.1, "milliliter", "1/4 fl oz"));
    expect(recipe.ingredients[2].quantity).toMatchObject({ kind: "range", lower: 568, upper: 1137, unit: "milliliter", originalText: "1-2 pints" });
    expect(recipe.ingredients[0].quantity.unit).toBe("gram");
    expect(() => validateCanonicalRecipe(recipe)).not.toThrow();
    const units = JSON.stringify(recipe).match(/"unit":"[^"]+"/gu)!.map((match) => match.slice(8, -1));
    expect(units.every((unit) => legacyUnitIDs.includes(unit))).toBe(true);
  });

  it("keeps UK units for builds that list them, and US units for every build", () => {
    const supported = [...legacyUnitIDs, "imperialPint", "imperialFluidOunce"];
    const recipe = recipeWithMilk(quantity(1, "imperialPint", "1 pint"), quantity(1, "pint", "1 US pint"));
    const before = structuredClone(recipe);
    adaptRecipeUnitsForClient(recipe, supported);
    expect(recipe).toEqual(before);

    adaptRecipeUnitsForClient(recipe, [...legacyUnitIDs]);
    expect(recipe.ingredients[1].quantity.unit).toBe("milliliter");
    expect(recipe.stages[0].ingredientUses[1].quantity).toEqual(quantity(1, "pint", "1 US pint"));
  });
});
