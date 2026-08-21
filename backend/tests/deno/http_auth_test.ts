// Plumbing tests: response shapes, caller identification, and the small pure
// utilities the functions lean on. No network, no permissions.

import assert from "node:assert/strict";
import {
  CORS_HEADERS,
  errorResponse,
  handleOptions,
  HttpError,
  json,
  readJsonBody,
  requireMethod,
} from "../../supabase/functions/_shared/http.ts";
import {
  bearerToken,
  decodeJwtPayload,
  isServiceRoleToken,
  subjectFromJwt,
} from "../../supabase/functions/_shared/auth.ts";
import {
  base64UrlDecodeBytes,
  base64UrlDecodeString,
  base64UrlEncode,
  chunk,
  readEnv,
} from "../../supabase/functions/_shared/util.ts";

function fakeJwt(payload: Record<string, unknown>): string {
  return [
    base64UrlEncode(JSON.stringify({ alg: "HS256", typ: "JWT" })),
    base64UrlEncode(JSON.stringify(payload)),
    "not-a-real-signature",
  ].join(".");
}

// ------------------------------------------------------------------------ util

Deno.test("chunk splits into runs of at most n", () => {
  assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
  assert.deepEqual(chunk([], 100), []);
  assert.deepEqual(chunk([1, 2], 100), [[1, 2]]);
  assert.equal(chunk(new Array(250).fill("p"), 100).length, 3);
  assert.throws(() => chunk([1], 0), /size/);
});

Deno.test("base64url round-trips, unpadded, unicode-safe", () => {
  const text = 'salaam 🤝 {"a":1}';
  const encoded = base64UrlEncode(text);
  assert.equal(/[+/=]/.test(encoded), false);
  assert.equal(base64UrlDecodeString(encoded), text);
  assert.deepEqual(
    Array.from(
      base64UrlDecodeBytes(base64UrlEncode(new Uint8Array([0, 255, 16])))!,
    ),
    [0, 255, 16],
  );
  assert.equal(base64UrlDecodeBytes("!!!"), null);
});

Deno.test("readEnv never throws without --allow-env", () => {
  assert.doesNotThrow(() => readEnv("APNS_KEY"));
  assert.doesNotThrow(() => readEnv("DEFINITELY_NOT_SET_1234"));
});

// ------------------------------------------------------------------------ http

Deno.test("json() answers with CORS + JSON content type", async () => {
  const res = json({ ok: true, sent: false }, 200);
  assert.equal(res.status, 200);
  assert.equal(
    res.headers.get("content-type"),
    "application/json; charset=utf-8",
  );
  assert.equal(
    res.headers.get("access-control-allow-origin"),
    CORS_HEADERS["access-control-allow-origin"],
  );
  assert.deepEqual(await res.json(), { ok: true, sent: false });
});

Deno.test("handleOptions answers preflight and passes everything else through", () => {
  const preflight = handleOptions(
    new Request("https://x/notify", { method: "OPTIONS" }),
  );
  assert.equal(preflight?.status, 204);
  assert.equal(
    handleOptions(new Request("https://x/notify", { method: "POST" })),
    null,
  );
});

Deno.test("requireMethod rejects anything but the documented verbs", () => {
  requireMethod(new Request("https://x", { method: "POST" }), ["POST"]);
  assert.throws(
    () => requireMethod(new Request("https://x", { method: "GET" }), ["POST"]),
    (err: unknown) => {
      assert.ok(err instanceof HttpError);
      assert.equal(err.status, 405);
      assert.equal(err.code, "method_not_allowed");
      return true;
    },
  );
});

Deno.test("readJsonBody tolerates an empty body, rejects broken JSON", async () => {
  assert.deepEqual(
    await readJsonBody(new Request("https://x", { method: "POST", body: "" })),
    {},
  );
  assert.deepEqual(
    await readJsonBody(
      new Request("https://x", { method: "POST", body: '{"kind":"join"}' }),
    ),
    { kind: "join" },
  );
  await assert.rejects(
    () =>
      readJsonBody(new Request("https://x", { method: "POST", body: "{oops" })),
    (err: unknown) => {
      assert.ok(err instanceof HttpError);
      assert.equal(err.status, 400);
      assert.equal(err.code, "invalid_json");
      return true;
    },
  );
});

Deno.test("errorResponse surfaces HttpError and hides everything else", async () => {
  const known = errorResponse(new HttpError(401, "invalid_token", "nope"));
  assert.equal(known.status, 401);
  assert.deepEqual(await known.json(), {
    ok: false,
    error: "invalid_token",
    message: "nope",
  });

  const originalError = console.error;
  console.error = () => {};
  try {
    const unknownErr = errorResponse(
      new Error("connection string leaked here"),
    );
    assert.equal(unknownErr.status, 500);
    const body = await unknownErr.json();
    assert.deepEqual(body, { ok: false, error: "internal_error" });
    assert.equal(JSON.stringify(body).includes("leaked"), false);

    // REGRESSION: an HttpError's message was returned for every status. Every
    // 5xx in this codebase is built from a PostgREST/Postgres error, so that
    // handed any authenticated caller constraint names, column names and
    // function signatures — from a public repo with public logs.
    const serverErr = errorResponse(
      new HttpError(
        500,
        "devices_lookup_failed",
        'relation "public.devices" violates constraint devices_pkey',
      ),
    );
    assert.equal(serverErr.status, 500);
    const serverBody = await serverErr.json();
    assert.deepEqual(serverBody, { ok: false, error: "devices_lookup_failed" });
    assert.equal(JSON.stringify(serverBody).includes("devices_pkey"), false);
  } finally {
    console.error = originalError;
  }
});

// ------------------------------------------------------------------------ auth

Deno.test("bearerToken parses the Authorization header", () => {
  assert.equal(bearerToken("Bearer abc.def.ghi"), "abc.def.ghi");
  assert.equal(bearerToken("bearer abc.def.ghi"), "abc.def.ghi");
  assert.equal(bearerToken("  Bearer   abc.def.ghi  "), "abc.def.ghi");
  assert.equal(bearerToken("Basic abc"), null);
  assert.equal(bearerToken("Bearer "), null);
  assert.equal(bearerToken(""), null);
  assert.equal(bearerToken(null), null);
});

Deno.test("decodeJwtPayload reads claims without pretending to verify", () => {
  const jwt = fakeJwt({ sub: "user-1", role: "authenticated" });
  assert.deepEqual(decodeJwtPayload(jwt), {
    sub: "user-1",
    role: "authenticated",
  });
  assert.equal(decodeJwtPayload("sb_secret_opaque_key"), null);
  assert.equal(decodeJwtPayload("a.b"), null);
  assert.equal(decodeJwtPayload("a.!!!.c"), null);
  assert.equal(decodeJwtPayload(`a.${base64UrlEncode("[1,2]")}.c`), null);
  assert.equal(decodeJwtPayload(`a.${base64UrlEncode("nope")}.c`), null);
  assert.equal(subjectFromJwt(jwt), "user-1");
  assert.equal(subjectFromJwt(fakeJwt({})), null);
});

Deno.test("isServiceRoleToken believes the injected key and nothing else", () => {
  // Both shapes of the real credential, compared verbatim.
  assert.equal(isServiceRoleToken("sb_secret_abc", "sb_secret_abc"), true);
  const realJwt = fakeJwt({ role: "service_role" });
  assert.equal(isServiceRoleToken(realJwt, realJwt), true);

  assert.equal(isServiceRoleToken("sb_secret_abc", "sb_secret_xyz"), false);
  assert.equal(isServiceRoleToken("sb_secret_abc", ""), false);
  assert.equal(isServiceRoleToken("sb_secret_abc", undefined), false);

  // REGRESSION: a self-asserted `role: service_role` claim used to be enough.
  // The one caller uses this answer to unlock retention's destructive `days`
  // knob, so a decoded — i.e. unverified — claim meant anyone who could reach
  // the function could POST {"days":1} and wipe every photo in the project.
  // Only the platform's verify_jwt flag stood in the way, and that is a config
  // switch, not a boundary.
  assert.equal(isServiceRoleToken(fakeJwt({ role: "service_role" })), false);
  assert.equal(
    isServiceRoleToken(fakeJwt({ role: "service_role" }), "sb_secret_abc"),
    false,
  );
  assert.equal(
    isServiceRoleToken(fakeJwt({ role: "authenticated", sub: "u" })),
    false,
  );
});
