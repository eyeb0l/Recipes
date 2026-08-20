export function validRecipe(): any {
  return {
    schemaVersion: 1,
    id: "test-pancakes",
    title: "Test Pancakes",
    summary: null,
    yield: { servings: 2, label: "2 servings" },
    ingredients: [
      { id: "flour", name: "flour", quantity: { kind: "exact", value: 100, lower: null, upper: null, text: null, unit: "gram", originalText: "100 g" }, scalable: true, notes: null, sortIndex: 0 }
    ],
    prepTasks: [],
    workstreams: [{ id: "pan", name: "Pan", sortIndex: 0 }],
    stages: [
      {
        id: "mix", action: "Mix", instruction: "Mix the flour with water.", completionCue: "Smooth batter", workstreamID: "pan",
        dependencies: [], ingredientUses: [{ ingredientID: "flour", quantity: null, stateChange: "mixed into batter" }], resultLabel: "Batter",
        duration: null, timers: [], heat: null, temperature: null, notes: null, sortIndex: 0
      }
    ],
    uncertainties: [],
    provenance: { sourceType: "text", url: null, title: null, cleanedText: "test", importedAt: "2026-08-18T00:00:00Z" }
  };
}

export class MemoryKV {
  values = new Map<string, string>();
  async get(key: string, type?: string) {
    const value = this.values.get(key) ?? null;
    return type === "json" && value ? JSON.parse(value) : value;
  }
  async put(key: string, value: string) { this.values.set(key, value); }
  async delete(key: string) { this.values.delete(key); }
}

export function testEnv(overrides: Partial<Env> = {}): Env {
  return {
    SESSIONS: new MemoryKV() as unknown as KVNamespace,
    IMPORT_RATE_LIMITER: { limit: async () => ({ success: true }) },
    APPLE_CLIENT_ID: "com.irisgiertuga.RecipeTimeline",
    SESSION_SIGNING_KEY: "test-only-session-signing-key-at-least-32-bytes",
    RECIPE_PROVIDER: "openai",
    GROK_MODEL: "grok-4.6",
    OPENAI_MODEL: "gpt-5.6-luna",
    XAI_API_KEY: "xai-test",
    OPENAI_API_KEY: "sk-test",
    ...overrides
  };
}
