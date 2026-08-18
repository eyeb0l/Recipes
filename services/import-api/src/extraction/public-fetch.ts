import { APIError } from "../errors";

const maximumBytes = 2_000_000;
const maximumRedirects = 4;
const allowedContentTypes = ["text/html", "application/xhtml+xml", "application/ld+json", "application/json"];

export type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
export type HostResolver = (hostname: string) => Promise<string[]>;

export interface PublicPage {
  finalURL: string;
  contentType: string;
  body: string;
}

export async function fetchPublicRecipe(
  sourceURL: string,
  fetcher: Fetcher = fetch,
  resolveHost: HostResolver = (hostname) => resolvePublicHost(hostname, fetcher)
): Promise<PublicPage> {
  let current = parsePublicURL(sourceURL);
  for (let redirect = 0; redirect <= maximumRedirects; redirect += 1) {
    await assertPublicHost(current.hostname, resolveHost);
    const response = await fetcher(current, {
      method: "GET",
      redirect: "manual",
      signal: AbortSignal.timeout(8_000),
      headers: {
        Accept: "text/html,application/ld+json,application/json;q=0.8",
        "User-Agent": "RecipeTimeline/1.0 (+recipe import; no archiving)"
      }
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      if (redirect === maximumRedirects) throw new APIError(422, "too_many_redirects", "The recipe page redirected too many times.");
      const location = response.headers.get("Location");
      if (!location) throw new APIError(422, "invalid_redirect", "The recipe page returned an invalid redirect.");
      current = parsePublicURL(new URL(location, current).toString());
      continue;
    }
    if (!response.ok) {
      throw new APIError(422, "source_unavailable", "The recipe page could not be read. Paste its recipe text or scan the page instead.");
    }
    const contentType = (response.headers.get("Content-Type") ?? "").split(";", 1)[0]?.trim().toLowerCase() ?? "";
    if (!allowedContentTypes.includes(contentType)) {
      throw new APIError(415, "unsupported_source_type", "The URL did not return a supported recipe page.");
    }
    const declared = Number(response.headers.get("Content-Length") ?? 0);
    if (declared > maximumBytes) throw new APIError(413, "source_too_large", "The recipe page is too large to import.");
    return { finalURL: current.toString(), contentType, body: await readLimitedText(response, maximumBytes) };
  }
  throw new APIError(422, "source_unavailable", "The recipe page could not be read.");
}

export function parsePublicURL(value: string): URL {
  let url: URL;
  try { url = new URL(value); } catch { throw new APIError(400, "invalid_url", "Enter a valid public HTTP or HTTPS URL."); }
  if (!new Set(["http:", "https:"]).has(url.protocol) || url.username || url.password || !url.hostname) {
    throw new APIError(400, "invalid_url", "Enter a public HTTP or HTTPS URL without embedded credentials.");
  }
  if (isForbiddenHostname(url.hostname)) {
    throw new APIError(400, "private_network_url", "Private-network and local URLs cannot be imported.");
  }
  return url;
}

export function isForbiddenHostname(hostname: string): boolean {
  const normalized = hostname.toLowerCase().replace(/^\[|\]$/gu, "").replace(/\.$/u, "");
  if (normalized === "localhost" || normalized.endsWith(".localhost") || normalized.endsWith(".local") || normalized.endsWith(".internal")) return true;
  return isForbiddenIPAddress(normalized);
}

export function isForbiddenIPAddress(value: string): boolean {
  if (value.includes(":")) {
    const lower = value.toLowerCase();
    return lower === "::" || lower === "::1" || lower.startsWith("fe80:") || lower.startsWith("fc") || lower.startsWith("fd") || lower.startsWith("::ffff:127.") || lower.startsWith("::ffff:10.") || lower.startsWith("::ffff:192.168.");
  }
  if (!/^\d{1,3}(?:\.\d{1,3}){3}$/u.test(value)) return false;
  const octets = value.split(".").map(Number);
  if (octets.some((part) => part > 255)) return true;
  const [a = 0, b = 0] = octets;
  return a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 0) || (a === 192 && b === 168) || (a === 198 && (b === 18 || b === 19));
}

async function assertPublicHost(hostname: string, resolver: HostResolver): Promise<void> {
  if (isForbiddenHostname(hostname)) throw new APIError(400, "private_network_url", "Private-network and local URLs cannot be imported.");
  if (isIPAddress(hostname)) return;
  const addresses = await resolver(hostname);
  if (addresses.length === 0 || addresses.some(isForbiddenIPAddress)) {
    throw new APIError(400, "private_network_url", "The URL does not resolve exclusively to a public network.");
  }
}

function isIPAddress(hostname: string): boolean {
  return hostname.includes(":") || /^\d{1,3}(?:\.\d{1,3}){3}$/u.test(hostname);
}

async function resolvePublicHost(hostname: string, fetcher: Fetcher): Promise<string[]> {
  const values = new Set<string>();
  for (const type of ["A", "AAAA"] as const) {
    const url = new URL("https://cloudflare-dns.com/dns-query");
    url.searchParams.set("name", hostname);
    url.searchParams.set("type", type);
    const response = await fetcher(url, { headers: { Accept: "application/dns-json" }, signal: AbortSignal.timeout(3_000) });
    if (!response.ok) throw new APIError(422, "dns_failed", "The recipe host could not be resolved safely.");
    const payload = await response.json() as { Answer?: Array<{ type: number; data: string }> };
    for (const answer of payload.Answer ?? []) {
      if ((answer.type === 1 || answer.type === 28) && isIPAddress(answer.data)) values.add(answer.data);
    }
  }
  return [...values];
}

async function readLimitedText(response: Response, limit: number): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      throw new APIError(413, "source_too_large", "The recipe page is too large to import.");
    }
    chunks.push(value);
  }
  const combined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { combined.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder().decode(combined);
}
