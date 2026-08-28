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

/// Drops the cached provider token for these credentials.
///
/// Apple answers 403 ExpiredProviderToken when the container's clock has drifted
/// or the .p8 was rotated under a warm isolate. Without this the same stale JWT
/// is re-sent on every subsequent push from that isolate — for up to the full
/// 50-minute TTL — and because 403 is not "unregistered", no device row is
/// dropped either: pushes just silently stop.
export function invalidateAPNsToken(
  creds: Pick<APNsCredentials, "keyId" | "teamId">,
): void {
  tokenCache.delete(`${creds.teamId}:${creds.keyId}`);
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
  /// v5 §5-B: run the app's Notification Service Extension before the banner
  /// is shown. The extension's only job is `reloadAllTimelines()`, which is the
  /// one way a friend's post reaches a home-screen widget with the app closed.
  ///
  /// It changes NOTHING about the notification a person sees — the extension
  /// hands `request.content` straight back — and it is safe on a device with an
  /// older build installed: a phone with no such extension simply ignores the
  /// key and shows the alert.
  mutableContent?: boolean;
  data?: Record<string, unknown>;
}): Record<string, unknown> {
  const aps: Record<string, unknown> = {
    alert: { title: opts.alert.title, body: opts.alert.body },
    sound: opts.sound === undefined ? "default" : opts.sound ?? undefined,
  };
  if (aps.sound === undefined) delete aps.sound;
  if (opts.threadId) aps["thread-id"] = opts.threadId;
  if (opts.category) aps.category = opts.category;
  if (opts.mutableContent) aps["mutable-content"] = 1;

  const payload: Record<string, unknown> = { aps };
  for (const [key, value] of Object.entries(opts.data ?? {})) {
    if (value !== undefined && value !== null) payload[key] = value;
  }
  return payload;
}

/// v5 §5 — the reload-only push: `content-available` and the custom data, and
/// nothing a person can see.
///
/// A SEPARATE function rather than a nullable `alert` on the one above, because
/// the property that matters is "there is no way for a title to end up in
/// here". §6's collapsed alert (one per prayer window per friend) is right for
/// the tray and must not move; what it leaves behind is a widget sitting on
/// "3 of 5" while the fourth and fifth post arrive. This is what tells the
/// phone to go and look, with no banner, no sound and no badge.
///
/// It is delivered to `AppDelegate.didReceiveRemoteNotification` and to the
/// notification service extension NEVER — that one runs for alerts only. Apple
/// throttles background pushes and guarantees nothing about them, which is
/// exactly why §5 calls this a bonus and not the mechanism.
export function buildSilentAPNsPayload(
  opts: { data?: Record<string, unknown> } = {},
): Record<string, unknown> {
  const payload: Record<string, unknown> = { aps: { "content-available": 1 } };
  for (const [key, value] of Object.entries(opts.data ?? {})) {
    if (value !== undefined && value !== null) payload[key] = value;
  }
  return payload;
}

/// v5 §6 — a Live Activity payload. `content-state` replaces `alert`, the
/// activity's own `attributes` come along on a start, and there is a hard 4 KB
/// ceiling on the whole thing (see `LIVE_ACTIVITY_PAYLOAD_LIMIT`).
///
/// A liveactivity push goes out at 10 like an alert, not at 5 like a background
/// push: priority 5 tells Apple it may be delayed for power, and an activity
/// that says "3 of 5 prayed" twenty minutes late is worse than one that never
/// updated at all. (Apple accepts both here; 5 is for battery-friendly
/// housekeeping, which this is not.)
export const APNS_LIVE_ACTIVITY_PUSH_TYPE = "liveactivity";
export const APNS_LIVE_ACTIVITY_PRIORITY = 10;

// ------------------------------------------------------- the Live Activity (§6)

/// What a liveactivity push is doing to the activity on the other end.
///
/// `start` creates one that is not there (push-to-start) and is the only event
/// that carries `attributes`; `update` moves a running one; `end` retires it.
///
/// The app ends its own activity WHEN IT IS RUNNING — `LiveActivityController`
/// on the Swift side, from `publishWidgetSnapshot` — which is not the same as
/// "at the window's close", and the difference is why `end` is here. Nothing
/// schedules a client-side end: ActivityKit has no request-time dismissal date
/// and `staleDate` only dims the card. So a phone that is asleep when its window
/// closes keeps a "window closed" card until it is next picked up, unless one of
/// these arrives first. See backend/README.md, "Who starts a Live Activity" —
/// the gap is documented at both ends there.
export type LiveActivityEvent = "start" | "update" | "end";

/// Apple's ceiling on a Live Activity payload. §6 states it as the reason the
/// content state carries "emoji/names/counts/tier colours only; photos only if
/// already in the shared container" — there is no way to send a picture, and a
/// payload one byte over this is rejected whole (413/PayloadTooLarge), not
/// truncated.
export const LIVE_ACTIVITY_PAYLOAD_LIMIT = 4096;

/// How many bytes a built payload actually costs, UTF-8, as Apple counts it.
/// Exported so the fan-out can trim BEFORE spending a round trip on a payload
/// Apple will refuse.
export function apnsPayloadBytes(payload: Record<string, unknown>): number {
  return new TextEncoder().encode(JSON.stringify(payload)).length;
}

export function fitsLiveActivityBudget(payload: Record<string, unknown>): boolean {
  return apnsPayloadBytes(payload) <= LIVE_ACTIVITY_PAYLOAD_LIMIT;
}

/// Builds the `aps` block ActivityKit decodes on the device.
///
/// The shape is Apple's and every key is load-bearing:
///   * `timestamp` — seconds. ActivityKit DISCARDS an update whose timestamp is
///     older than the one it already applied, which is what makes two pushes
///     racing over the same window safe. It is the payload's, not the request's.
///   * `event` — see `LiveActivityEvent`.
///   * `content-state` — decoded as `PrayerWindowAttributes.ContentState`
///     (Sources/Shared/PrayerWindowActivity.swift). The two shapes are the same
///     shape or the push is silently dropped, so the Swift side decodes
///     tolerantly and every key here is one it names.
///   * `attributes-type` / `attributes` — the STATIC half of the activity, and
///     required on `start` only. `attributes-type` is the Swift type's name,
///     spelled once in `LIVE_ACTIVITY_ATTRIBUTES_TYPE`.
///   * `stale-date` — when the system should start showing the activity as out
///     of date. The window's end, always: an activity that outlives its prayer
///     is the thing §6 says must not happen.
///   * `dismissal-date` — when the system retires an ENDED activity from the
///     Lock Screen. Meaningless on start/update and omitted there.
///
/// No `alert` is emitted. A start push may carry one, and deliberately does
/// not: §5's post announcement is already the banner for this event, and a
/// second one for the same fact is exactly the kind of withdrawal from the push
/// permission §6 is careful about.
export function buildLiveActivityPayload(opts: {
  event: LiveActivityEvent;
  contentState: Record<string, unknown>;
  timestampSeconds: number;
  attributesType?: string;
  attributes?: Record<string, unknown>;
  staleSeconds?: number;
  dismissalSeconds?: number;
  relevanceScore?: number;
  data?: Record<string, unknown>;
}): Record<string, unknown> {
  const aps: Record<string, unknown> = {
    timestamp: Math.floor(opts.timestampSeconds),
    event: opts.event,
    "content-state": opts.contentState,
  };
  if (opts.event === "start") {
    // Apple refuses a start with no attributes, and there is no sensible
    // default: the attributes ARE which prayer window this activity is about.
    if (!opts.attributesType || !opts.attributes) {
      throw new Error("a live activity start push needs attributes");
    }
    aps["attributes-type"] = opts.attributesType;
    aps.attributes = opts.attributes;
  }
  if (opts.staleSeconds !== undefined) {
    aps["stale-date"] = Math.floor(opts.staleSeconds);
  }
  if (opts.event === "end" && opts.dismissalSeconds !== undefined) {
    aps["dismissal-date"] = Math.floor(opts.dismissalSeconds);
  }
  if (opts.relevanceScore !== undefined) {
    aps["relevance-score"] = opts.relevanceScore;
  }

  const payload: Record<string, unknown> = { aps };
  for (const [key, value] of Object.entries(opts.data ?? {})) {
    if (value !== undefined && value !== null) payload[key] = value;
  }
  return payload;
}

/// Apple's push type for a payload with no alert in it, and the priority it
/// insists on. A background push sent at priority 10 is rejected outright
/// (`BadPriority`), which would make the §5 reload look like a silent no-op.
export const APNS_BACKGROUND_PUSH_TYPE = "background";
export const APNS_BACKGROUND_PRIORITY = 5;

// -------------------------------------------------------------- the apns-topic

/// SPEC-V5 §1: "Live Activities need a different `apns-topic` suffix, and
/// that's the only line that assumes a bare bundle id." This is that line,
/// lifted out of `sendAPNs` and made pure so it is testable and so there is
/// exactly one place the rule lives.
///
/// An alert, a background push and a nudge all address the APP
/// (`org.amacvoters.salahbuddymock`). A Live Activity addresses a different
/// endpoint of the same app and Apple routes it by topic:
/// `<bundle id>.push-type.liveactivity`. Send one to the bare id and Apple
/// answers 400/TopicDisallowed — which looks exactly like a misconfigured key
/// from the outside, i.e. like nothing at all.
export const APNS_LIVE_ACTIVITY_TOPIC_SUFFIX = ".push-type.liveactivity";

export function apnsTopic(bundleId: string, pushType?: string | null): string {
  if (pushType !== APNS_LIVE_ACTIVITY_PUSH_TYPE) return bundleId;
  // Idempotent: APNS_BUNDLE_ID is a deployment secret, and somebody eventually
  // sets it to the suffixed form after reading Apple's docs. Appending a second
  // copy would be a silent 400 on every Live Activity push.
  return bundleId.endsWith(APNS_LIVE_ACTIVITY_TOPIC_SUFFIX)
    ? bundleId
    : `${bundleId}${APNS_LIVE_ACTIVITY_TOPIC_SUFFIX}`;
}
/// What everything else goes out at, and `sendAPNs`' default. Named so the
/// header and the skip log below read it from the same place — a log that
/// reported a priority the request did not carry would be worse than no log.
export const APNS_ALERT_PRIORITY = 10;

// ------------------------------------------------------------------- delivery

export interface DeviceRow {
  user_id: string;
  apns_token: string;
  environment: APNsEnvironment | string;
  /// The device's UTC offset in seconds (20260822000500). Optional and
  /// nullable: rows registered by an older build have no answer, and `_shared/
  /// zones.ts` reads that as "cannot judge, send anyway". Nothing in THIS file
  /// looks at it — delivery does not care where a phone is — it rides along
  /// because `devicesFor` selects the row once and `notify` filters it before
  /// handing the list here.
  utc_offset?: number | null;
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
  /// 400/BadDeviceToken: retry against the other APNs host before believing it.
  wrongEnvironment?: boolean;
  error?: string;
}

/// Apple's way of saying "this token is gone": 410, and an explicit
/// Unregistered reason.
///
/// 400/BadDeviceToken is deliberately NOT here. Apple returns it for a token
/// that does not belong to the host it was sent to — which is exactly what a
/// TestFlight/dev build looks like when it registers a sandbox token against
/// the production host (devices.environment is client-supplied and defaults to
/// 'production'). Treating that as "dead" deletes a perfectly good row and the
/// user silently never receives another push. `isWrongEnvironment` routes it to
/// a retry against the other host instead; only if BOTH reject does the row go.
export function isUnregistered(
  status: number,
  reason?: string | null,
): boolean {
  if (status === 410) return true;
  return status === 400 && reason === "Unregistered";
}

/// 400/BadDeviceToken: either a genuinely bogus token, or the right token sent
/// to the wrong APNs host. Only a retry can tell the two apart.
export function isWrongEnvironment(
  status: number,
  reason?: string | null,
): boolean {
  return status === 400 && reason === "BadDeviceToken";
}

/// A provider token Apple will not accept any more — the cached JWT has to go.
export function isStaleProviderToken(
  status: number,
  reason?: string | null,
): boolean {
  return status === 403 &&
    (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken");
}

export function otherEnvironment(
  environment: APNsEnvironment | string | null | undefined,
): APNsEnvironment {
  return environment === "sandbox" ? "production" : "sandbox";
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
  /// Milliseconds before the request to Apple is abandoned. One hung HTTP/2
  /// connection must not be able to eat the whole invocation's wall clock —
  /// the fan-out behind it still has other devices to reach.
  timeoutMs?: number;
}

export const APNS_REQUEST_TIMEOUT_MS = 5000;

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

  const attempt = async (
    forceRefresh: boolean,
  ): Promise<{ status: number; reason?: string }> => {
    const jwt = await signAPNsJWT(creds, {
      // A refresh mints against the CURRENT clock. Re-signing at the same pinned
      // instant would reproduce the very token Apple just called expired.
      nowSeconds: forceRefresh ? undefined : opts.nowSeconds,
      forceRefresh,
    });
    const headers: Record<string, string> = {
      authorization: `bearer ${jwt}`,
      // v5 §6: a Live Activity is a different topic on the same app. See
      // `apnsTopic` — this used to be a bare `creds.bundleId`, which §1 named
      // as the one line that would have to change.
      "apns-topic": apnsTopic(creds.bundleId, opts.pushType),
      "apns-push-type": opts.pushType ?? "alert",
      "apns-priority": String(opts.priority ?? APNS_ALERT_PRIORITY),
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
      signal: AbortSignal.timeout(opts.timeoutMs ?? APNS_REQUEST_TIMEOUT_MS),
    });

    // Always drain: an undrained body leaves the HTTP/2 stream open.
    const text = await response.text().catch(() => "");
    return { status: response.status, reason: parseAPNsReason(text) };
  };

  try {
    let { status, reason } = await attempt(false);

    // A stale provider token is the standard warm-isolate failure (clock drift,
    // or a rotated .p8). Nothing else in the pipeline would ever clear it, so
    // one push would poison every push from this isolate for up to 50 minutes.
    if (isStaleProviderToken(status, reason)) {
      log("apns: provider token rejected — refreshing and retrying once", {
        reason,
      });
      invalidateAPNsToken(creds);
      ({ status, reason } = await attempt(true));
    }

    if (status === 200) return { ...base, delivered: true, status: 200 };

    const unregistered = isUnregistered(status, reason);
    log("apns: delivery failed", { status, reason, unregistered });
    return {
      ...base,
      status,
      reason,
      unregistered,
      wrongEnvironment: isWrongEnvironment(status, reason),
    };
  } catch (err) {
    // Signing failure (bad .p8), a timeout, or a transport failure — log, never
    // throw: one dead device must not take the rest of the fan-out with it.
    log("apns: send threw", { error: String(err) });
    return { ...base, error: String(err), reason: "send_failed" };
  }
}

/// Whether a built payload asks for the notification service extension.
/// Reads the payload rather than an option, because by the time delivery has it
/// the payload IS the fact — an option that was dropped on the way here would
/// still read as "true" from the wrong side of the decision.
function mutableContentOf(payload: Record<string, unknown>): boolean {
  const aps = payload.aps;
  if (typeof aps !== "object" || aps === null) return false;
  return (aps as Record<string, unknown>)["mutable-content"] === 1;
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
  /// Tokens that turned out to be registered against the OTHER APNs host.
  reenvironmented: { token: string; environment: APNsEnvironment }[];
  results: APNsSendResult[];
}

/// How many pushes are in flight at once. A serial `for … await` over a whole
/// circle is fine at 7 devices and fatal at 700: at a realistic 40 ms round trip
/// it is the difference between 0.3 s and half a minute inside one Edge Function
/// invocation. Small enough to stay polite to Apple, wide enough that a slow
/// device cannot hold up the rest.
export const APNS_FAN_OUT_CONCURRENCY = 6;

/// Fans one payload out to a set of device rows.
///
/// `onUnregistered` / `onEnvironmentChanged` are injected rather than imported
/// so this module never needs to know about Supabase — which is what keeps it
/// unit-testable offline.
export async function deliverToDevices(
  devices: readonly DeviceRow[],
  payload: Record<string, unknown>,
  opts: {
    credentials?: APNsCredentials | null;
    onUnregistered?: (token: string) => Promise<void> | void;
    onEnvironmentChanged?: (
      token: string,
      environment: APNsEnvironment,
    ) => Promise<void> | void;
    fetchImpl?: typeof fetch;
    log?: Logger;
    collapseId?: string;
    expiration?: number;
    concurrency?: number;
    timeoutMs?: number;
    /// v5 §5: `"background"` for a reload-only payload. Absent means `"alert"`,
    /// which is `sendAPNs`' own default and every push before this one.
    pushType?: string;
    /// Paired with `pushType` — Apple rejects a background push at 10.
    priority?: number;
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
    reenvironmented: [],
    results: [],
  };

  if (!creds) {
    // One line, not one per device — an unconfigured environment is normal.
    //
    // The three fields beyond the count are the v5 §5 decisions, and they are
    // here because they answer the same operational question: "why is nobody's
    // widget updating". A push that went as an `alert` when it should have been
    // a `background`, a background push sent at the alert priority (Apple
    // answers 400/BadPriority and NOTHING is delivered — not a dead token, not
    // an unregistered device, just a failure the reply still reports 200 over),
    // and an alert that did not ask for the notification service extension all
    // look exactly like Apple throttling from the outside — silent,
    // intermittent, and about somebody else's phone. This is the line that says
    // which. (`notify_test.ts` reads it for the same reason, and the shape is
    // one object with named keys rather than a message, so rewording the
    // sentence does not break it.)
    log("apns: not configured — skipping fan-out", {
      devices: devices.length,
      pushType: opts.pushType ?? "alert",
      priority: opts.priority ?? APNS_ALERT_PRIORITY,
      mutableContent: mutableContentOf(payload),
    });
    summary.skipped = devices.length;
    return summary;
  }

  const send = (
    device: DeviceRow,
    environment: APNsEnvironment | string | null | undefined,
  ) =>
    sendAPNs({
      token: device.apns_token,
      environment,
      payload,
      credentials: creds,
      collapseId: opts.collapseId,
      expiration: opts.expiration,
      pushType: opts.pushType,
      priority: opts.priority,
      fetchImpl: opts.fetchImpl,
      timeoutMs: opts.timeoutMs,
      log,
    });

  const deliverOne = async (device: DeviceRow) => {
    let result = await send(device, device.environment);

    // 400/BadDeviceToken usually means "right token, wrong host" — a TestFlight
    // build whose registration did not say `sandbox`. Ask the other host before
    // concluding the token is dead, and remember the answer.
    if (result.wrongEnvironment) {
      const flipped = otherEnvironment(device.environment);
      log("apns: BadDeviceToken — retrying against the other host", {
        environment: flipped,
      });
      const retry = await send(device, flipped);
      if (retry.delivered) {
        summary.reenvironmented.push({
          token: device.apns_token,
          environment: flipped,
        });
        try {
          await opts.onEnvironmentChanged?.(device.apns_token, flipped);
        } catch (err) {
          log("apns: failed to record the device environment", {
            error: String(err),
          });
        }
        result = retry;
      } else if (retry.wrongEnvironment) {
        // Rejected by both hosts: now it really is a dead token.
        result = { ...retry, unregistered: true };
      } else {
        result = retry;
      }
    }

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
  };

  const width = Math.max(1, opts.concurrency ?? APNS_FAN_OUT_CONCURRENCY);
  let next = 0;
  const workers = Array.from(
    { length: Math.min(width, devices.length) },
    async () => {
      while (true) {
        const index = next++;
        if (index >= devices.length) return;
        await deliverOne(devices[index]);
      }
    },
  );
  await Promise.all(workers);

  return summary;
}
