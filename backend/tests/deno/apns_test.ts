// Unit tests for the APNs helpers. Everything here is offline: the ES256 key is
// generated locally with WebCrypto and `fetch` is always injected, so these run
// with no network and no permissions.
//
//   deno test backend/tests/deno/

import assert from "node:assert/strict";
import {
  APNS_ENV_VARS,
  APNS_TOKEN_TTL_SECONDS,
  apnsConfigured,
  apnsCredentialsFrom,
  apnsHost,
  apnsUrl,
  buildAPNsJWTClaims,
  buildAPNsPayload,
  deliverToDevices,
  envRecord,
  isUnregistered,
  parseAPNsReason,
  pemToPkcs8,
  resetAPNsTokenCache,
  sendAPNs,
  signAPNsJWT,
} from "../../supabase/functions/_shared/apns.ts";
import {
  base64UrlDecodeBytes,
  base64UrlDecodeString,
} from "../../supabase/functions/_shared/util.ts";

// ---------------------------------------------------------------- test key

interface TestKey {
  pem: string;
  publicKey: CryptoKey;
}

async function generateTestKey(): Promise<TestKey> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  let binary = "";
  for (const byte of pkcs8) binary += String.fromCharCode(byte);
  const base64 = btoa(binary).replace(/(.{64})/g, "$1\n");
  const pem =
    `-----BEGIN PRIVATE KEY-----\n${base64}\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: pair.publicKey };
}

function creds(pem: string) {
  return {
    key: pem,
    keyId: "ABCD123456",
    teamId: "TEAM123456",
    bundleId: "org.amacvoters.salahbuddymock",
  };
}

const FULL_ENV: Record<string, string> = {
  APNS_KEY: "-----BEGIN PRIVATE KEY-----\nMIG\n-----END PRIVATE KEY-----",
  APNS_KEY_ID: "ABCD123456",
  APNS_TEAM_ID: "TEAM123456",
  APNS_BUNDLE_ID: "org.amacvoters.salahbuddymock",
};

// -------------------------------------------------------------- configuration

Deno.test("apnsConfigured is true only when every APNS_* var is present", () => {
  assert.equal(apnsConfigured(envRecord(FULL_ENV)), true);

  for (const missing of APNS_ENV_VARS) {
    const partial = { ...FULL_ENV };
    delete partial[missing];
    assert.equal(
      apnsConfigured(envRecord(partial)),
      false,
      `expected unconfigured when ${missing} is missing`,
    );
  }
});

Deno.test("apnsConfigured treats blank/whitespace values as missing", () => {
  assert.equal(
    apnsConfigured(envRecord({ ...FULL_ENV, APNS_KEY_ID: "" })),
    false,
  );
  assert.equal(
    apnsConfigured(envRecord({ ...FULL_ENV, APNS_TEAM_ID: "   " })),
    false,
  );
  assert.equal(apnsCredentialsFrom(envRecord({})), null);
});

Deno.test("apnsConfigured never throws when the env is unreadable", () => {
  // No --allow-env in the test run: a permission failure must read as
  // "not configured", not as an exception.
  assert.doesNotThrow(() => apnsConfigured());
});

Deno.test("apnsCredentialsFrom trims surrounding whitespace", () => {
  const parsed = apnsCredentialsFrom(
    envRecord({ ...FULL_ENV, APNS_KEY_ID: "  ABCD123456  " }),
  );
  assert.equal(parsed?.keyId, "ABCD123456");
});

// ------------------------------------------------------------------ PEM → DER

Deno.test("pemToPkcs8 strips the armour and decodes to DER", async () => {
  const { pem } = await generateTestKey();
  const der = pemToPkcs8(pem);
  assert.ok(der.length > 32);
  assert.equal(der[0], 0x30); // DER SEQUENCE — a PKCS#8 PrivateKeyInfo.
});

Deno.test("pemToPkcs8 accepts a single line with literal \\n escapes", async () => {
  const { pem } = await generateTestKey();
  const escaped = pem.replace(/\n/g, "\\n");
  assert.deepEqual(
    Array.from(pemToPkcs8(escaped)),
    Array.from(pemToPkcs8(pem)),
  );
});

Deno.test("pemToPkcs8 accepts a bare base64 body with no header", async () => {
  const { pem } = await generateTestKey();
  const bare = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "");
  assert.deepEqual(Array.from(pemToPkcs8(bare)), Array.from(pemToPkcs8(pem)));
});

Deno.test("pemToPkcs8 rejects empty and non-base64 keys", () => {
  assert.throws(() => pemToPkcs8(""), /empty/);
  assert.throws(() => pemToPkcs8("   "), /empty/);
  assert.throws(
    () =>
      pemToPkcs8("-----BEGIN PRIVATE KEY-----\n\n-----END PRIVATE KEY-----"),
    /no base64 body/,
  );
  assert.throws(() => pemToPkcs8("not a key!!"), /not valid base64/);
});

// ------------------------------------------------------------------ JWT

Deno.test("buildAPNsJWTClaims produces Apple's provider-token shape", () => {
  const { header, payload } = buildAPNsJWTClaims({
    teamId: "TEAM123456",
    keyId: "ABCD123456",
    nowSeconds: 1_770_000_000.9,
  });
  assert.deepEqual(header, { alg: "ES256", kid: "ABCD123456" });
  assert.deepEqual(payload, { iss: "TEAM123456", iat: 1_770_000_000 });
  // No `exp`: Apple keys the token's life off `iat` (60 minutes).
  assert.equal("exp" in payload, false);
});

Deno.test("buildAPNsJWTClaims requires both ids", () => {
  assert.throws(
    () => buildAPNsJWTClaims({ teamId: "", keyId: "K", nowSeconds: 0 }),
    /teamId/,
  );
  assert.throws(
    () => buildAPNsJWTClaims({ teamId: "T", keyId: "", nowSeconds: 0 }),
    /keyId/,
  );
});

Deno.test("signAPNsJWT signs an ES256 token the public key verifies", async () => {
  resetAPNsTokenCache();
  const { pem, publicKey } = await generateTestKey();
  const jwt = await signAPNsJWT(creds(pem), { nowSeconds: 1_770_000_000 });

  const parts = jwt.split(".");
  assert.equal(parts.length, 3);
  assert.deepEqual(JSON.parse(base64UrlDecodeString(parts[0])!), {
    alg: "ES256",
    kid: "ABCD123456",
  });
  assert.deepEqual(JSON.parse(base64UrlDecodeString(parts[1])!), {
    iss: "TEAM123456",
    iat: 1_770_000_000,
  });
  assert.equal(/[+/=]/.test(jwt), false, "must be base64url, unpadded");

  const signature = base64UrlDecodeBytes(parts[2])!;
  assert.equal(signature.length, 64, "ES256 signature is raw r||s");
  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    signature,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  assert.equal(verified, true);
});

Deno.test("signAPNsJWT caches the token for ~50 minutes", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  const base = 1_770_000_000;

  const first = await signAPNsJWT(creds(pem), { nowSeconds: base });
  const cached = await signAPNsJWT(creds(pem), {
    nowSeconds: base + APNS_TOKEN_TTL_SECONDS - 1,
  });
  assert.equal(cached, first, "still inside the cache window");

  const refreshed = await signAPNsJWT(creds(pem), {
    nowSeconds: base + APNS_TOKEN_TTL_SECONDS + 1,
  });
  assert.notEqual(refreshed, first, "expired — must re-sign");
  assert.equal(APNS_TOKEN_TTL_SECONDS, 50 * 60);

  const forced = await signAPNsJWT(creds(pem), {
    nowSeconds: base,
    forceRefresh: true,
  });
  assert.notEqual(forced, refreshed);
  resetAPNsTokenCache();
});

// -------------------------------------------------------------------- payload

Deno.test("apnsHost/apnsUrl route sandbox tokens to Apple's sandbox", () => {
  assert.equal(apnsHost("production"), "api.push.apple.com");
  assert.equal(apnsHost("sandbox"), "api.sandbox.push.apple.com");
  assert.equal(apnsHost(undefined), "api.push.apple.com");
  assert.equal(apnsHost("nonsense"), "api.push.apple.com");
  assert.equal(
    apnsUrl("abc123", "sandbox"),
    "https://api.sandbox.push.apple.com/3/device/abc123",
  );
});

Deno.test("buildAPNsPayload emits aps plus custom keys, dropping empties", () => {
  const payload = buildAPNsPayload({
    alert: { title: "T", body: "B" },
    threadId: "circle-1",
    category: "CIRCLE_POST",
    data: { kind: "post", postId: "p1", nothing: null, alsoNothing: undefined },
  });
  assert.deepEqual(payload, {
    aps: {
      alert: { title: "T", body: "B" },
      sound: "default",
      "thread-id": "circle-1",
      category: "CIRCLE_POST",
    },
    kind: "post",
    postId: "p1",
  });
});

Deno.test("buildAPNsPayload omits optional aps keys when unset", () => {
  const payload = buildAPNsPayload({
    alert: { title: "T", body: "B" },
    sound: null,
  });
  assert.deepEqual(payload, { aps: { alert: { title: "T", body: "B" } } });
});

// ------------------------------------------------------------------- delivery

Deno.test("isUnregistered covers 410 and 400/BadDeviceToken only", () => {
  assert.equal(isUnregistered(410), true);
  assert.equal(isUnregistered(410, "Unregistered"), true);
  assert.equal(isUnregistered(400, "BadDeviceToken"), true);
  assert.equal(isUnregistered(400, "Unregistered"), true);
  assert.equal(isUnregistered(400, "PayloadTooLarge"), false);
  assert.equal(isUnregistered(429, "TooManyRequests"), false);
  assert.equal(isUnregistered(200), false);
});

Deno.test("parseAPNsReason reads Apple's error body", () => {
  assert.equal(
    parseAPNsReason('{"reason":"BadDeviceToken"}'),
    "BadDeviceToken",
  );
  assert.equal(parseAPNsReason(""), undefined);
  assert.equal(parseAPNsReason("<html>502</html>"), undefined);
  assert.equal(parseAPNsReason('{"reason":42}'), undefined);
});

function recordingFetch(
  responder: (url: string, init: RequestInit) => Response,
): { impl: typeof fetch; calls: { url: string; init: RequestInit }[] } {
  const calls: { url: string; init: RequestInit }[] = [];
  const impl = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return Promise.resolve(responder(String(input), init ?? {}));
  }) as unknown as typeof fetch;
  return { impl, calls };
}

const silent = () => {};

Deno.test("sendAPNs skips (never throws) when APNs is unconfigured", async () => {
  const { impl, calls } = recordingFetch(() =>
    new Response(null, { status: 200 })
  );
  const result = await sendAPNs({
    token: "device-1",
    payload: { aps: {} },
    credentials: null,
    fetchImpl: impl,
    log: silent,
  });
  assert.equal(result.skipped, true);
  assert.equal(result.delivered, false);
  assert.equal(result.reason, "apns_not_configured");
  assert.equal(calls.length, 0, "must not touch the network");
});

Deno.test("sendAPNs skips an empty device token", async () => {
  const { impl, calls } = recordingFetch(() =>
    new Response(null, { status: 200 })
  );
  const { pem } = await generateTestKey();
  const result = await sendAPNs({
    token: "",
    payload: { aps: {} },
    credentials: creds(pem),
    fetchImpl: impl,
    log: silent,
  });
  assert.equal(result.skipped, true);
  assert.equal(calls.length, 0);
});

Deno.test("sendAPNs posts to Apple with the provider token and topic", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  const { impl, calls } = recordingFetch(() =>
    new Response("", { status: 200 })
  );
  const result = await sendAPNs({
    token: "device-1",
    environment: "sandbox",
    payload: { aps: { alert: { title: "T", body: "B" } } },
    credentials: creds(pem),
    collapseId: "post-1",
    fetchImpl: impl,
    log: silent,
  });

  assert.equal(result.delivered, true);
  assert.equal(result.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(
    calls[0].url,
    "https://api.sandbox.push.apple.com/3/device/device-1",
  );
  assert.equal(calls[0].init.method, "POST");
  const headers = calls[0].init.headers as Record<string, string>;
  assert.match(headers.authorization, /^bearer eyJ/);
  assert.equal(headers["apns-topic"], "org.amacvoters.salahbuddymock");
  assert.equal(headers["apns-push-type"], "alert");
  assert.equal(headers["apns-priority"], "10");
  assert.equal(headers["apns-collapse-id"], "post-1");
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), {
    aps: { alert: { title: "T", body: "B" } },
  });
  resetAPNsTokenCache();
});

Deno.test("sendAPNs reports a 410 as unregistered", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  const { impl } = recordingFetch(() =>
    new Response('{"reason":"Unregistered"}', { status: 410 })
  );
  const result = await sendAPNs({
    token: "dead-token",
    payload: { aps: {} },
    credentials: creds(pem),
    fetchImpl: impl,
    log: silent,
  });
  assert.equal(result.delivered, false);
  assert.equal(result.unregistered, true);
  assert.equal(result.status, 410);
  assert.equal(result.reason, "Unregistered");
  resetAPNsTokenCache();
});

Deno.test("sendAPNs swallows transport failures", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  const impl =
    (() => Promise.reject(new Error("boom"))) as unknown as typeof fetch;
  const result = await sendAPNs({
    token: "device-1",
    payload: { aps: {} },
    credentials: creds(pem),
    fetchImpl: impl,
    log: silent,
  });
  assert.equal(result.delivered, false);
  assert.equal(result.reason, "send_failed");
  assert.match(String(result.error), /boom/);
  resetAPNsTokenCache();
});

Deno.test("sendAPNs swallows a malformed signing key", async () => {
  resetAPNsTokenCache();
  const { impl, calls } = recordingFetch(() =>
    new Response("", { status: 200 })
  );
  const result = await sendAPNs({
    token: "device-1",
    payload: { aps: {} },
    credentials: { ...creds("not a key!!") },
    fetchImpl: impl,
    log: silent,
  });
  assert.equal(result.delivered, false);
  assert.equal(result.reason, "send_failed");
  assert.equal(calls.length, 0);
  resetAPNsTokenCache();
});

Deno.test("deliverToDevices drops device rows Apple rejects", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  const { impl } = recordingFetch((url) =>
    url.endsWith("/dead")
      ? new Response('{"reason":"BadDeviceToken"}', { status: 400 })
      : new Response("", { status: 200 })
  );
  const dropped: string[] = [];
  const summary = await deliverToDevices(
    [
      { user_id: "u1", apns_token: "live", environment: "production" },
      { user_id: "u2", apns_token: "dead", environment: "sandbox" },
    ],
    { aps: {} },
    {
      credentials: creds(pem),
      fetchImpl: impl,
      log: silent,
      onUnregistered: (token) => {
        dropped.push(token);
      },
    },
  );
  assert.equal(summary.attempted, 2);
  assert.equal(summary.delivered, 1);
  assert.deepEqual(summary.unregistered, ["dead"]);
  assert.deepEqual(dropped, ["dead"]);
  resetAPNsTokenCache();
});

Deno.test("deliverToDevices log-and-skips the whole fan-out when unconfigured", async () => {
  const { impl, calls } = recordingFetch(() =>
    new Response("", { status: 200 })
  );
  const logged: string[] = [];
  const summary = await deliverToDevices(
    [
      { user_id: "u1", apns_token: "a", environment: "production" },
      { user_id: "u2", apns_token: "b", environment: "production" },
    ],
    { aps: {} },
    { credentials: null, fetchImpl: impl, log: (m) => logged.push(m) },
  );
  assert.equal(summary.delivered, 0);
  assert.equal(summary.skipped, 2);
  assert.deepEqual(summary.unregistered, []);
  assert.equal(calls.length, 0);
  assert.equal(logged.length, 1, "one line, not one per device");
});

Deno.test("deliverToDevices survives a failing onUnregistered hook", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  const { impl } = recordingFetch(() => new Response("", { status: 410 }));
  const summary = await deliverToDevices(
    [{ user_id: "u1", apns_token: "dead", environment: "production" }],
    { aps: {} },
    {
      credentials: creds(pem),
      fetchImpl: impl,
      log: silent,
      onUnregistered: () => Promise.reject(new Error("db down")),
    },
  );
  assert.deepEqual(summary.unregistered, ["dead"]);
  resetAPNsTokenCache();
});
