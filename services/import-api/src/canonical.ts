import recipeSchema from "../../../schema/recipe-v1.json";
import { APIError } from "./errors";

export const canonicalRecipeSchema = recipeSchema as Record<string, unknown>;

interface CanonicalRecipe {
  schemaVersion: number;
  id: string;
  title: string;
  yield: { servings: number | string };
  ingredients: Array<{ id: string; name: string; sortIndex: number }>;
  prepTasks: Array<{ id: string; ingredientIDs: string[] }>;
  workstreams: Array<{ id: string }>;
  stages: Array<{
    id: string;
    workstreamID?: string | null;
    dependencies: string[];
    ingredientUses: Array<{ ingredientID: string }>;
  }>;
  uncertainties: Array<{ ingredientIDs: string[]; stageIDs: string[] }>;
  provenance: { sourceType: string };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasString(value: Record<string, unknown>, key: string): boolean {
  return typeof value[key] === "string" && (value[key] as string).trim().length > 0;
}

export function validateCanonicalRecipe(value: unknown): asserts value is CanonicalRecipe {
  validateAgainstSchema(value, canonicalRecipeSchema, "$", canonicalRecipeSchema);
  if (!isObject(value) || value.schemaVersion !== 1 || !hasString(value, "id") || !hasString(value, "title")) {
    throw new APIError(502, "invalid_model_output", "The provider returned an invalid recipe header.");
  }
  if (!isObject(value.yield) || !(typeof value.yield.servings === "number" || typeof value.yield.servings === "string")) {
    throw new APIError(502, "invalid_model_output", "The provider returned an invalid recipe yield.");
  }
  for (const key of ["ingredients", "prepTasks", "workstreams", "stages", "uncertainties"] as const) {
    if (!Array.isArray(value[key])) {
      throw new APIError(502, "invalid_model_output", `The provider omitted ${key}.`);
    }
  }
  if (!isObject(value.provenance) || !hasString(value.provenance, "sourceType")) {
    throw new APIError(502, "invalid_model_output", "The provider returned invalid provenance.");
  }

  const recipe = value as unknown as CanonicalRecipe;
  const duplicate = (ids: string[]) => ids.length !== new Set(ids).size;
  const ingredientIDs = recipe.ingredients.map((item) => item.id);
  const stageIDs = recipe.stages.map((item) => item.id);
  const workstreamIDs = recipe.workstreams.map((item) => item.id);
  if (ingredientIDs.some((id) => !id) || stageIDs.some((id) => !id) || duplicate(ingredientIDs) || duplicate(stageIDs) || duplicate(workstreamIDs)) {
    throw new APIError(502, "invalid_model_output", "The provider returned duplicate or empty identifiers.");
  }

  const ingredients = new Set(ingredientIDs);
  const stages = new Set(stageIDs);
  const workstreams = new Set(workstreamIDs);
  for (const task of recipe.prepTasks) {
    if (!task.ingredientIDs.every((id) => ingredients.has(id))) dangling("prep ingredient");
  }
  for (const stage of recipe.stages) {
    if (stage.workstreamID && !workstreams.has(stage.workstreamID)) dangling("workstream");
    if (!stage.dependencies.every((id) => stages.has(id)) || stage.dependencies.includes(stage.id)) dangling("stage dependency");
    if (!stage.ingredientUses.every((use) => ingredients.has(use.ingredientID))) dangling("stage ingredient");
  }
  for (const uncertainty of recipe.uncertainties) {
    if (!uncertainty.ingredientIDs.every((id) => ingredients.has(id)) || !uncertainty.stageIDs.every((id) => stages.has(id))) {
      dangling("uncertainty reference");
    }
  }
  validateAcyclic(recipe.stages);

  const used = new Set(recipe.stages.flatMap((stage) => stage.ingredientUses.map((use) => use.ingredientID)));
  const uncertain = new Set(recipe.uncertainties.flatMap((item) => item.ingredientIDs));
  if (ingredientIDs.some((id) => !used.has(id) && !uncertain.has(id))) {
    throw new APIError(502, "invalid_model_output", "An ingredient is unused without a corresponding uncertainty.");
  }
}

function validateAgainstSchema(
  value: unknown,
  schema: Record<string, unknown>,
  path: string,
  root: Record<string, unknown>
): void {
  if (typeof schema.$ref === "string") {
    const segments = schema.$ref.replace(/^#\//u, "").split("/");
    let resolved: unknown = root;
    for (const segment of segments) resolved = isObject(resolved) ? resolved[segment] : undefined;
    if (!isObject(resolved)) schemaFailure(path);
    validateAgainstSchema(value, resolved, path, root);
    return;
  }
  if (Array.isArray(schema.anyOf)) {
    const matches = schema.anyOf.some((candidate) => {
      try { validateAgainstSchema(value, candidate as Record<string, unknown>, path, root); return true; } catch { return false; }
    });
    if (!matches) schemaFailure(path);
    return;
  }
  if ("const" in schema && value !== schema.const) schemaFailure(path);
  if (Array.isArray(schema.enum) && !schema.enum.includes(value)) schemaFailure(path);
  const types = Array.isArray(schema.type) ? schema.type : schema.type ? [schema.type] : [];
  if (types.length && !types.some((type) => matchesType(value, String(type)))) schemaFailure(path);

  if (isObject(value)) {
    const required = Array.isArray(schema.required) ? schema.required.map(String) : [];
    if (required.some((key) => !(key in value))) schemaFailure(path);
    const properties = isObject(schema.properties) ? schema.properties : {};
    if (schema.additionalProperties === false && Object.keys(value).some((key) => !(key in properties))) schemaFailure(path);
    for (const [key, child] of Object.entries(properties)) {
      if (key in value && isObject(child)) validateAgainstSchema(value[key], child, `${path}.${key}`, root);
    }
  }
  if (Array.isArray(value)) {
    if (typeof schema.minItems === "number" && value.length < schema.minItems) schemaFailure(path);
    if (isObject(schema.items)) value.forEach((item, index) => validateAgainstSchema(item, schema.items as Record<string, unknown>, `${path}[${index}]`, root));
  }
  if (typeof value === "string" && typeof schema.minLength === "number" && value.length < schema.minLength) schemaFailure(path);
  if (typeof value === "number" && typeof schema.minimum === "number" && value < schema.minimum) schemaFailure(path);
  if (typeof value === "number" && typeof schema.exclusiveMinimum === "number" && value <= schema.exclusiveMinimum) schemaFailure(path);
}

function matchesType(value: unknown, type: string): boolean {
  switch (type) {
  case "null": return value === null;
  case "object": return isObject(value);
  case "array": return Array.isArray(value);
  case "string": return typeof value === "string";
  case "number": return typeof value === "number" && Number.isFinite(value);
  case "integer": return typeof value === "number" && Number.isInteger(value);
  case "boolean": return typeof value === "boolean";
  default: return true;
  }
}

function schemaFailure(path: string): never {
  throw new APIError(502, "invalid_model_output", `The provider output does not match RecipeV1 at ${path}.`);
}

function dangling(kind: string): never {
  throw new APIError(502, "invalid_model_output", `The provider returned a dangling ${kind}.`);
}

function validateAcyclic(stages: CanonicalRecipe["stages"]): void {
  const byID = new Map(stages.map((stage) => [stage.id, stage]));
  const visiting = new Set<string>();
  const visited = new Set<string>();
  const visit = (id: string): void => {
    if (visiting.has(id)) throw new APIError(502, "invalid_model_output", "The provider returned a cyclic stage graph.");
    if (visited.has(id)) return;
    visiting.add(id);
    for (const dependency of byID.get(id)?.dependencies ?? []) visit(dependency);
    visiting.delete(id);
    visited.add(id);
  };
  for (const stage of stages) visit(stage.id);
}
