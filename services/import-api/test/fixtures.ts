import type { QuotaDenial, QuotaOperation } from "../src/quota";

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

export class MemoryQuota {
  private readonly counts = new Map<string, { provider: number; fetch: number }>();

  getByName(name: string) {
    return {
      consume: async (_day: string, _subjectHash: string, operation: QuotaOperation): Promise<QuotaDenial | null> => {
        const usage = this.counts.get(name) ?? { provider: 0, fetch: 0 };
        if (operation !== "retry-fetch" && usage.provider >= 20) return "quota_exceeded";
        if (operation !== "provider" && usage.fetch >= 40) return "fetch_quota_exceeded";
        usage[operation === "provider" ? "provider" : "fetch"] += 1;
        this.counts.set(name, usage);
        return null;
      }
    };
  }

  // API fixtures use one authenticated subject per test.
  get usage() {
    return this.counts.values().next().value;
  }

  async seed(usage: { provider: number; fetch: number }) {
    const day = new Date().toISOString().slice(0, 10);
    this.counts.set(`${day}:${await fixtureSubjectHash()}`, usage);
  }
}

export async function fixtureSubjectHash(subject = "opaque-apple-subject") {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(subject));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function memoryQuota(env: Env) {
  return env.DAILY_QUOTA as unknown as MemoryQuota;
}

export function testEnv(overrides: Partial<Env> = {}): Env {
  return {
    SESSIONS: new MemoryKV() as unknown as KVNamespace,
    DAILY_QUOTA: new MemoryQuota() as unknown as Env["DAILY_QUOTA"],
    IMPORT_RATE_LIMITER: { limit: async () => ({ success: true }) },
    APPLE_CLIENT_ID: "com.irisgiertuga.RecipeTimeline",
    SESSION_SIGNING_KEY: "test-only-session-signing-key-at-least-32-bytes",
    OPENAI_MODEL: "gpt-6.1-terra",
    OPENAI_API_KEY: "sk-test",
    ...overrides
  };
}
