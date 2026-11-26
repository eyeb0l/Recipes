import { DurableObject } from "cloudflare:workers";
import type { QuotaDenial, QuotaOperation } from "./quota";

interface Usage {
  provider: number;
  fetch: number;
}

const dailyProviderLimit = 20;
const dailyFetchLimit = 40;

export class DailyQuota extends DurableObject<Env> {
  async consume(day: string, subjectHash: string, operation: QuotaOperation): Promise<QuotaDenial | null> {
    const storage = this.ctx.storage;
    const expiresAt = Date.parse(`${day}T00:00:00.000Z`) + 2 * 86_400_000;
    let legacy: Usage | undefined;
    if (!storage.kv.get<Usage>("usage")) {
      const [provider, fetch] = await Promise.all([
        this.env.SESSIONS.get(`quota:${day}:${subjectHash}`),
        this.env.SESSIONS.get(`fetch-quota:${day}:${subjectHash}`)
      ]);
      legacy = { provider: Number(provider ?? 0), fetch: Number(fetch ?? 0) };
    }

    return storage.transaction(async (txn) => {
      // The KV reads can overlap across requests. Only the first transaction seeds the counters.
      let usage = await txn.get<Usage>("usage");
      if (!usage) {
        if (!legacy || Date.now() >= expiresAt) throw new Error("Daily quota window expired");
        usage = legacy;
        await txn.setAlarm(expiresAt);
        await txn.put("usage", usage);
      }

      if (operation !== "retry-fetch" && usage.provider >= dailyProviderLimit) return "quota_exceeded";
      if (operation !== "provider" && usage.fetch >= dailyFetchLimit) return "fetch_quota_exceeded";

      const bucket = operation === "provider" ? "provider" : "fetch";
      await txn.put("usage", { ...usage, [bucket]: usage[bucket] + 1 });
      return null;
    });
  }

  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}
