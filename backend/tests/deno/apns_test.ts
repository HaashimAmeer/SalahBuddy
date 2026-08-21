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
  invalidateAPNsToken,
  isStaleProviderToken,
  isUnregistered,
  isWrongEnvironment,
  otherEnvironment,
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

Deno.test("isUnregistered means 410/Unregistered — NOT BadDeviceToken", () => {
  assert.equal(isUnregistered(410), true);
  assert.equal(isUnregistered(410, "Unregistered"), true);
  assert.equal(isUnregistered(400, "Unregistered"), true);
  assert.equal(isUnregistered(400, "PayloadTooLarge"), false);
  assert.equal(isUnregistered(429, "TooManyRequests"), false);
  assert.equal(isUnregistered(200), false);

  // REGRESSION: 400/BadDeviceToken used to delete the device row outright. It
  // is what Apple answers for a token sent to the WRONG HOST — exactly what a
  // TestFlight build looks like when it registers a sandbox token while
  // devices.environment defaults to 'production'. Deleting it there loses push
  // for that user permanently, with nothing to re-trigger a registration.
  assert.equal(isUnregistered(400, "BadDeviceToken"), false);
  assert.equal(isWrongEnvironment(400, "BadDeviceToken"), true);
  assert.equal(isWrongEnvironment(410, "Unregistered"), false);
  assert.equal(otherEnvironment("production"), "sandbox");
  assert.equal(otherEnvironment("sandbox"), "production");
  assert.equal(otherEnvironment(undefined), "sandbox");

  assert.equal(isStaleProviderToken(403, "ExpiredProviderToken"), true);
  assert.equal(isStaleProviderToken(403, "InvalidProviderToken"), true);
  assert.equal(isStaleProviderToken(403, "Forbidden"), false);
  assert.equal(isStaleProviderToken(400, "ExpiredProviderToken"), false);
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
      ? new Response('{"reason":"Unregistered"}', { status: 410 })
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

Deno.test("a BadDeviceToken is retried on the other host before it is believed", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  // The classic TestFlight mix-up: a sandbox token registered as 'production'.
  const { impl, calls } = recordingFetch((url) =>
    url.includes("api.sandbox.push.apple.com")
      ? new Response("", { status: 200 })
      : new Response('{"reason":"BadDeviceToken"}', { status: 400 })
  );
  const dropped: string[] = [];
  const flipped: { token: string; environment: string }[] = [];
  const summary = await deliverToDevices(
    [{ user_id: "u1", apns_token: "sandbox-token", environment: "production" }],
    { aps: {} },
    {
      credentials: creds(pem),
      fetchImpl: impl,
      log: silent,
      onUnregistered: (t) => {
        dropped.push(t);
      },
      onEnvironmentChanged: (token, environment) => {
        flipped.push({ token, environment });
      },
    },
  );

  assert.equal(summary.delivered, 1, "the token was live all along");
  assert.deepEqual(summary.unregistered, [], "a live device must not be deleted");
  assert.deepEqual(dropped, []);
  assert.deepEqual(flipped, [{
    token: "sandbox-token",
    environment: "sandbox",
  }]);
  assert.equal(calls.length, 2, "one try per host");
  resetAPNsTokenCache();
});

Deno.test("a token both hosts reject really is dead", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  const { impl } = recordingFetch(() =>
    new Response('{"reason":"BadDeviceToken"}', { status: 400 })
  );
  const dropped: string[] = [];
  const summary = await deliverToDevices(
    [{ user_id: "u1", apns_token: "garbage", environment: "production" }],
    { aps: {} },
    {
      credentials: creds(pem),
      fetchImpl: impl,
      log: silent,
      onUnregistered: (t) => {
        dropped.push(t);
      },
    },
  );
  assert.deepEqual(summary.unregistered, ["garbage"]);
  assert.deepEqual(dropped, ["garbage"]);
  resetAPNsTokenCache();
});

Deno.test("an expired provider token is refreshed and the push retried", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  let seen = 0;
  const tokens: string[] = [];
  const { impl } = recordingFetch((_url, init) => {
    tokens.push(String((init.headers as Record<string, string>).authorization));
    seen += 1;
    // First call: Apple says the JWT is stale (clock drift, or a rotated .p8).
    return seen === 1
      ? new Response('{"reason":"ExpiredProviderToken"}', { status: 403 })
      : new Response("", { status: 200 });
  });

  const result = await sendAPNs({
    token: "device-1",
    payload: { aps: {} },
    credentials: creds(pem),
    fetchImpl: impl,
    log: silent,
    // Distinct iat values so the refreshed JWT is observably different.
    nowSeconds: 1_800_000_000,
  });

  assert.equal(result.delivered, true);
  assert.equal(seen, 2, "the push was retried once");
  // REGRESSION: nothing invalidated the cache, so every push from a warm
  // isolate re-sent the byte-identical dead JWT for up to the 50-minute TTL —
  // and 403 is not "unregistered", so no device row was dropped either. Pushes
  // simply stopped, silently. The refreshed token must also be minted against
  // the current clock: re-signing at the pinned instant would reproduce the
  // token Apple just rejected.
  assert.notEqual(tokens[0], tokens[1], "the same dead JWT was re-sent");
  const iatOf = (header: string) =>
    JSON.parse(
      new TextDecoder().decode(
        base64UrlDecodeBytes(header.split(" ")[1].split(".")[1])!,
      ),
    ).iat as number;
  assert.equal(iatOf(tokens[0]), 1_800_000_000);
  assert.notEqual(iatOf(tokens[1]), 1_800_000_000);
  resetAPNsTokenCache();
});

Deno.test("invalidateAPNsToken forces the next signature to be fresh", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  const c = { key: pem, keyId: "KEYID12345", teamId: "TEAMID1234" };
  const first = await signAPNsJWT(c, { nowSeconds: 1_800_000_000 });
  assert.equal(await signAPNsJWT(c, { nowSeconds: 1_800_000_010 }), first);
  invalidateAPNsToken(c);
  assert.notEqual(await signAPNsJWT(c, { nowSeconds: 1_800_000_010 }), first);
  resetAPNsTokenCache();
});

Deno.test("the fan-out is bounded, not serial, and carries an expiry", async () => {
  resetAPNsTokenCache();
  const { pem } = await generateTestKey();
  let inFlight = 0;
  let peak = 0;
  const expirations = new Set<string>();
  const impl = ((_input: string | URL | Request, init?: RequestInit) => {
    const headers = (init?.headers ?? {}) as Record<string, string>;
    expirations.add(headers["apns-expiration"] ?? "absent");
    inFlight += 1;
    peak = Math.max(peak, inFlight);
    return new Promise<Response>((resolve) =>
      setTimeout(() => {
        inFlight -= 1;
        resolve(new Response("", { status: 200 }));
      }, 5)
    );
  }) as unknown as typeof fetch;

  const devices = Array.from({ length: 24 }, (_, i) => ({
    user_id: `u${i}`,
    apns_token: `t${i}`,
    environment: "production",
  }));
  const summary = await deliverToDevices(devices, { aps: {} }, {
    credentials: creds(pem),
    fetchImpl: impl,
    log: silent,
    expiration: 1_800_003_600,
    concurrency: 4,
  });

  assert.equal(summary.delivered, 24);
  // REGRESSION (a): `for … await` sent one push at a time, so a member with
  // hundreds of device rows could push their circle's fan-out past the Edge
  // Function wall clock — every notification for that circle then died.
  assert.ok(peak > 1, `fan-out was serial (peak concurrency ${peak})`);
  assert.ok(peak <= 4, `fan-out exceeded its bound (peak ${peak})`);
  // REGRESSION (b): apns-expiration was never set, so Apple's default
  // store-and-retry applied and a window-bound nudge could land days later.
  assert.deepEqual([...expirations], ["1800003600"]);
  resetAPNsTokenCache();
});
