// APNs provider-token push, signed in-process with WebCrypto.
//
// Why no third-party push service: the whole point of v4's backend is that
// SalahBuddy's data stays in one place we control. Apple's HTTP/2 API takes an
// ES256 "provider token" (a JWT signed with the .p8 auth key), which Deno can
// mint natively — so there is nothing else to trust and nothing else to pay for.
//
// Discipline this module enforces:
//   * `apnsConfigured()` is false when ANY APNS_* var is missing, and every
//     delivery path LOGS AND SKIPS instead of throwing. Unit tests, local runs
//     and any environment without a push key must all run clean.
//   * A 410 (or 400/BadDeviceToken) means the token is dead: the caller is
//     handed the token back so it can delete the `devices` row.
//   * The signing + payload building are pure and exported, so the tests cover
//     them with a locally generated key and zero network.

import { base64UrlEncode, readEnv } from "./util.ts";
import type { Alert } from "./messages.ts";

// ---------------------------------------------------------------- credentials

export const APNS_ENV_VARS = [
  "APNS_KEY",
  "APNS_KEY_ID",
  "APNS_TEAM_ID",
  "APNS_BUNDLE_ID",
] as const;

export interface APNsCredentials {
  /// Contents of the .p8 file (PKCS#8 PEM). Never checked into the repo —
  /// set with `supabase secrets set APNS_KEY="$(cat AuthKey_XXXX.p8)"`.
  key: string;
  keyId: string;
  teamId: string;
  bundleId: string;
}

export type EnvLike = { get(name: string): string | undefined };

const processEnv: EnvLike = { get: readEnv };

/// Pure over an env source so tests can pass a plain record.
export function apnsCredentialsFrom(
  env: EnvLike = processEnv,
): APNsCredentials | null {
  const values = APNS_ENV_VARS.map((name) => env.get(name)?.trim());
  if (values.some((v) => v === undefined || v === "")) return null;
  const [key, keyId, teamId, bundleId] = values as string[];
  return { key, keyId, teamId, bundleId };
}

/// False when any APNS_* var is missing — the single gate every send path checks.
export function apnsConfigured(env: EnvLike = processEnv): boolean {
  return apnsCredentialsFrom(env) !== null;
}

export function envRecord(record: Record<string, string | undefined>): EnvLike {
  return { get: (name) => record[name] };
}

// ------------------------------------------------------------------ JWT / key

export const APNS_TOKEN_TTL_SECONDS = 50 * 60; // Apple rejects tokens older than 60m.

export interface APNsJWTClaims {
  header: { alg: "ES256"; kid: string };
  payload: { iss: string; iat: number };
}

/// The exact header/payload Apple expects for a provider token.
export function buildAPNsJWTClaims(opts: {
  teamId: string;
  keyId: string;
  nowSeconds: number;
}): APNsJWTClaims {
  if (!opts.teamId) throw new Error("APNs teamId is required");
  if (!opts.keyId) throw new Error("APNs keyId is required");
  return {
    header: { alg: "ES256", kid: opts.keyId },
    payload: { iss: opts.teamId, iat: Math.floor(opts.nowSeconds) },
  };
}

const PEM_BODY_RE =
  /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----([\s\S]*?)-----END (?:[A-Z ]+ )?PRIVATE KEY-----/;

/// Strips the PEM armour and base64-decodes to DER, ready for
/// `crypto.subtle.importKey("pkcs8", ...)`.
///
/// Tolerates the two ways a .p8 arrives from a secrets store: real newlines, or
/// a single line with literal `\n` escapes.
export function pemToPkcs8(pem: string): Uint8Array<ArrayBuffer> {
  if (typeof pem !== "string" || pem.trim() === "") {
    throw new Error("APNs key is empty");
  }
  const normalised = pem.replace(/\\r/g, "").replace(/\\n/g, "\n").trim();
  const match = PEM_BODY_RE.exec(normalised);
  const body = (match ? match[1] : normalised).replace(/\s+/g, "");
  if (body === "") throw new Error("APNs key contains no base64 body");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(body)) {
    throw new Error("APNs key is not valid base64 (expected a PKCS#8 .p8)");
  }
  let binary: string;
  try {
    binary = atob(body);
  } catch {
    throw new Error("APNs key is not valid base64 (expected a PKCS#8 .p8)");
  }
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

const keyCache = new Map<string, CryptoKey>();

export async function importAPNsSigningKey(
  pem: string,
  cacheKey?: string,
): Promise<CryptoKey> {
  const cached = cacheKey ? keyCache.get(cacheKey) : undefined;
  if (cached) return cached;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  if (cacheKey) keyCache.set(cacheKey, key);
  return key;
}

interface CachedToken {
  token: string;
  expiresAt: number;
}
const tokenCache = new Map<string, CachedToken>();

/// Test seam — also useful if a key is ever rotated inside a warm isolate.
export function resetAPNsTokenCache(): void {
  tokenCache.clear();
  keyCache.clear();
}

/// Signs (or returns the cached) ES256 provider token for these credentials.
/// WebCrypto's ECDSA signature is already raw r||s, which is exactly the JOSE
/// ES256 encoding — no DER unwrapping needed.
export async function signAPNsJWT(
  creds: Pick<APNsCredentials, "key" | "keyId" | "teamId">,
  opts: { nowSeconds?: number; forceRefresh?: boolean } = {},
): Promise<string> {
  const now = Math.floor(opts.nowSeconds ?? Date.now() / 1000);
  const cacheKey = `${creds.teamId}:${creds.keyId}`;
  if (!opts.forceRefresh) {
    const cached = tokenCache.get(cacheKey);
    if (cached && cached.expiresAt > now) return cached.token;
  }
  const { header, payload } = buildAPNsJWTClaims({
    teamId: creds.teamId,
    keyId: creds.keyId,
    nowSeconds: now,
  });
  const signingInput = `${base64UrlEncode(JSON.stringify(header))}.${
    base64UrlEncode(JSON.stringify(payload))
  }`;
  const signingKey = await importAPNsSigningKey(creds.key, cacheKey);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    signingKey,
    new TextEncoder().encode(signingInput),
  );
  const token = `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
  tokenCache.set(cacheKey, { token, expiresAt: now + APNS_TOKEN_TTL_SECONDS });
  return token;
}

// -------------------------------------------------------------------- payload

export type APNsEnvironment = "production" | "sandbox";

export function apnsHost(
  environment: APNsEnvironment | string | null | undefined,
): string {
  return environment === "sandbox"
    ? "api.sandbox.push.apple.com"
    : "api.push.apple.com";
}

export function apnsUrl(
  token: string,
  environment: APNsEnvironment | string | null | undefined,
): string {
  return `https://${apnsHost(environment)}/3/device/${token}`;
}

/// Builds the JSON body Apple expects. Custom keys ride alongside `aps` so the
/// app can deep-link the tap; only defined keys are emitted (Apple rejects
/// nulls in `aps`).
export function buildAPNsPayload(opts: {
  alert: Alert;
  threadId?: string | null;
  category?: string | null;
  sound?: string | null;
  data?: Record<string, unknown>;
}): Record<string, unknown> {
  const aps: Record<string, unknown> = {
    alert: { title: opts.alert.title, body: opts.alert.body },
    sound: opts.sound === undefined ? "default" : opts.sound ?? undefined,
  };
  if (aps.sound === undefined) delete aps.sound;
  if (opts.threadId) aps["thread-id"] = opts.threadId;
  if (opts.category) aps.category = opts.category;

  const payload: Record<string, unknown> = { aps };
  for (const [key, value] of Object.entries(opts.data ?? {})) {
    if (value !== undefined && value !== null) payload[key] = value;
  }
  return payload;
}

// ------------------------------------------------------------------- delivery

export interface DeviceRow {
  user_id: string;
  apns_token: string;
  environment: APNsEnvironment | string;
}

export interface APNsSendResult {
  token: string;
  delivered: boolean;
  /// True when we never even tried (APNs not configured on this deployment).
  skipped: boolean;
  status: number;
  reason?: string;
  /// The token is dead — delete the `devices` row.
  unregistered: boolean;
  error?: string;
}

/// Apple's way of saying "this token is gone": 410 always, and 400 with
/// BadDeviceToken for a token that never belonged to this topic.
export function isUnregistered(
  status: number,
  reason?: string | null,
): boolean {
  if (status === 410) return true;
  return status === 400 &&
    (reason === "BadDeviceToken" || reason === "Unregistered");
}

export type Logger = (message: string, meta?: Record<string, unknown>) => void;

const defaultLog: Logger = (message, meta) => {
  if (meta) console.log(message, JSON.stringify(meta));
  else console.log(message);
};

export interface SendAPNsOptions {
  token: string;
  environment?: APNsEnvironment | string | null;
  payload: Record<string, unknown>;
  credentials?: APNsCredentials | null;
  collapseId?: string;
  /// Unix seconds; 0 = "deliver now or drop" (Apple's default is store-and-retry).
  expiration?: number;
  priority?: number;
  pushType?: string;
  fetchImpl?: typeof fetch;
  log?: Logger;
  nowSeconds?: number;
}

/// Sends one push. NEVER throws: an unconfigured deployment, a malformed key
/// and a network blip all come back as a result object with `delivered: false`.
export async function sendAPNs(opts: SendAPNsOptions): Promise<APNsSendResult> {
  const log = opts.log ?? defaultLog;
  const creds = opts.credentials === undefined
    ? apnsCredentialsFrom()
    : opts.credentials;
  const base: APNsSendResult = {
    token: opts.token,
    delivered: false,
    skipped: false,
    status: 0,
    unregistered: false,
  };

  if (!creds) {
    log("apns: not configured — skipping push", { missing: APNS_ENV_VARS });
    return { ...base, skipped: true, reason: "apns_not_configured" };
  }
  if (!opts.token) {
    log("apns: empty device token — skipping push");
    return { ...base, skipped: true, reason: "empty_token" };
  }

  try {
    const jwt = await signAPNsJWT(creds, { nowSeconds: opts.nowSeconds });
    const headers: Record<string, string> = {
      authorization: `bearer ${jwt}`,
      "apns-topic": creds.bundleId,
      "apns-push-type": opts.pushType ?? "alert",
      "apns-priority": String(opts.priority ?? 10),
      "content-type": "application/json",
    };
    if (opts.collapseId) {
      headers["apns-collapse-id"] = opts.collapseId.slice(0, 64);
    }
    if (opts.expiration !== undefined) {
      headers["apns-expiration"] = String(opts.expiration);
    }

    const doFetch = opts.fetchImpl ?? fetch;
    const response = await doFetch(apnsUrl(opts.token, opts.environment), {
      method: "POST",
      headers,
      body: JSON.stringify(opts.payload),
    });

    if (response.status === 200) {
      // Drain the (empty) body so the HTTP/2 stream closes cleanly.
      await response.text().catch(() => "");
      return { ...base, delivered: true, status: 200 };
    }

    const text = await response.text().catch(() => "");
    const reason = parseAPNsReason(text);
    const unregistered = isUnregistered(response.status, reason);
    log("apns: delivery failed", {
      status: response.status,
      reason,
      unregistered,
    });
    return { ...base, status: response.status, reason, unregistered };
  } catch (err) {
    // Signing failure (bad .p8) or transport failure — log, never throw.
    log("apns: send threw", { error: String(err) });
    return { ...base, error: String(err), reason: "send_failed" };
  }
}

export function parseAPNsReason(body: string): string | undefined {
  if (!body) return undefined;
  try {
    const parsed = JSON.parse(body);
    const reason = (parsed as Record<string, unknown>)?.reason;
    return typeof reason === "string" ? reason : undefined;
  } catch {
    return undefined;
  }
}

export interface DeliverSummary {
  attempted: number;
  delivered: number;
  skipped: number;
  unregistered: string[];
  results: APNsSendResult[];
}

/// Fans one payload out to a set of device rows.
///
/// `onUnregistered` is injected rather than imported so this module never needs
/// to know about Supabase — which is what keeps it unit-testable offline.
export async function deliverToDevices(
  devices: readonly DeviceRow[],
  payload: Record<string, unknown>,
  opts: {
    credentials?: APNsCredentials | null;
    onUnregistered?: (token: string) => Promise<void> | void;
    fetchImpl?: typeof fetch;
    log?: Logger;
    collapseId?: string;
  } = {},
): Promise<DeliverSummary> {
  const log = opts.log ?? defaultLog;
  const creds = opts.credentials === undefined
    ? apnsCredentialsFrom()
    : opts.credentials;
  const summary: DeliverSummary = {
    attempted: devices.length,
    delivered: 0,
    skipped: 0,
    unregistered: [],
    results: [],
  };

  if (!creds) {
    // One line, not one per device — an unconfigured environment is normal.
    log("apns: not configured — skipping fan-out", { devices: devices.length });
    summary.skipped = devices.length;
    return summary;
  }

  for (const device of devices) {
    const result = await sendAPNs({
      token: device.apns_token,
      environment: device.environment,
      payload,
      credentials: creds,
      collapseId: opts.collapseId,
      fetchImpl: opts.fetchImpl,
      log,
    });
    summary.results.push(result);
    if (result.delivered) summary.delivered++;
    if (result.skipped) summary.skipped++;
    if (result.unregistered) {
      summary.unregistered.push(device.apns_token);
      try {
        await opts.onUnregistered?.(device.apns_token);
      } catch (err) {
        log("apns: failed to drop dead device row", { error: String(err) });
      }
    }
  }
  return summary;
}
