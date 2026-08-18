import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";
import { APIError } from "../errors";
import type { SessionClaims, SessionTokens } from "../types";

const appleJWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const accessLifetimeSeconds = 15 * 60;
const refreshLifetimeSeconds = 30 * 24 * 60 * 60;

interface StoredRefreshSession extends SessionClaims {
  expiresAt: string;
}

export async function verifyAppleIdentityToken(token: string, audience: string): Promise<string> {
  try {
    const { payload } = await jwtVerify(token, appleJWKS, {
      issuer: "https://appleid.apple.com",
      audience
    });
    if (!payload.sub) throw new Error("missing subject");
    return payload.sub;
  } catch {
    throw new APIError(401, "invalid_apple_token", "The Apple identity token could not be verified.");
  }
}

export async function issueSession(env: Env, subject: string): Promise<SessionTokens> {
  const now = new Date();
  const sid = crypto.randomUUID();
  const refreshToken = randomToken();
  const accessExpiresAt = new Date(now.getTime() + accessLifetimeSeconds * 1_000);
  const refreshExpiresAt = new Date(now.getTime() + refreshLifetimeSeconds * 1_000);
  const claims = { sub: subject, sid };
  const accessToken = await signAccessToken(env, claims, accessLifetimeSeconds);
  await env.SESSIONS.put(await refreshKey(refreshToken), JSON.stringify({ ...claims, expiresAt: refreshExpiresAt.toISOString() }), {
    expirationTtl: refreshLifetimeSeconds
  });
  return {
    accessToken,
    refreshToken,
    accessExpiresAt: accessExpiresAt.toISOString(),
    refreshExpiresAt: refreshExpiresAt.toISOString()
  };
}

export async function rotateSession(env: Env, currentToken: string): Promise<SessionTokens> {
  if (!currentToken || currentToken.length > 512) {
    throw new APIError(401, "invalid_refresh_token", "The refresh token is invalid.");
  }
  const key = await refreshKey(currentToken);
  const stored = await env.SESSIONS.get<StoredRefreshSession>(key, "json");
  if (!stored || new Date(stored.expiresAt) <= new Date()) {
    throw new APIError(401, "invalid_refresh_token", "The refresh token is invalid or expired.");
  }
  await env.SESSIONS.delete(key);
  return issueSession(env, stored.sub);
}

export async function authenticate(request: Request, env: Env): Promise<SessionClaims> {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) {
    throw new APIError(401, "missing_session", "A valid session is required.");
  }
  try {
    const { payload } = await jwtVerify(header.slice(7), signingKey(env), {
      issuer: "recipe-timeline-import-api",
      audience: "recipe-timeline-app"
    });
    if (!payload.sub || typeof payload.sid !== "string") throw new Error("missing claims");
    return { sub: payload.sub, sid: payload.sid };
  } catch {
    throw new APIError(401, "invalid_session", "The session is invalid or expired.");
  }
}

async function signAccessToken(env: Env, claims: SessionClaims, lifetime: number): Promise<string> {
  return new SignJWT({ sid: claims.sid })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(claims.sub)
    .setIssuer("recipe-timeline-import-api")
    .setAudience("recipe-timeline-app")
    .setIssuedAt()
    .setExpirationTime(`${lifetime}s`)
    .sign(signingKey(env));
}

function signingKey(env: Env): Uint8Array {
  if (!env.SESSION_SIGNING_KEY || env.SESSION_SIGNING_KEY.length < 32) {
    throw new APIError(500, "server_misconfigured", "Session signing is not configured.");
  }
  return new TextEncoder().encode(env.SESSION_SIGNING_KEY);
}

function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(48));
  return base64URL(bytes);
}

async function refreshKey(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return `refresh:${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}
