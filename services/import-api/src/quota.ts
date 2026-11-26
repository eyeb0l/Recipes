import { APIError } from "./errors";

export type QuotaOperation = "provider" | "fetch" | "retry-fetch";
export type QuotaDenial = "quota_exceeded" | "fetch_quota_exceeded";

export async function consumeDailyAllowance(env: Env, subjectHash: string, operation: QuotaOperation): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  const quota = env.DAILY_QUOTA.getByName(`${day}:${subjectHash}`);
  const denial = await quota.consume(day, subjectHash, operation);
  if (denial === "quota_exceeded") {
    throw new APIError(429, denial, "The daily private import allowance has been reached.");
  }
  if (denial === "fetch_quota_exceeded") {
    throw new APIError(429, denial, "Too many recipe links were tried today. Paste the recipe text or scan the page instead.");
  }
}
