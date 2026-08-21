// The notify body is attacker-controlled: these tests pin exactly which shapes
// get through, and the messages/copy the circle actually receives.

import assert from "node:assert/strict";
import {
  dayKeyWithinWindow,
  isDayKey,
  isPrayerKind,
  isUuid,
  normalizePhotoPaths,
  NOTIFY_KINDS,
  parseNotifyRequest,
  parseRetentionDays,
  parseRetentionMinutes,
  prayerDisplayName,
  PRAYERS,
  RETENTION_DEFAULT_DAYS,
  RETENTION_DEFAULT_MINUTES,
  RETENTION_MAX_DAYS,
  RETENTION_MAX_MINUTES,
  RETENTION_MIN_DAYS,
  retentionInterval,
  retentionParams,
} from "../../supabase/functions/_shared/validate.ts";
import { HttpError } from "../../supabase/functions/_shared/http.ts";
import {
  displayName,
  joinAlert,
  nudgeAlert,
  postAlert,
} from "../../supabase/functions/_shared/messages.ts";

const POST_ID = "3F2504E0-4F89-41D3-9A0C-0305E82C3301";
const USER_ID = "9c5b94b1-35ad-49bb-b118-8e8fc24abf80";

function expectHttpError(code: string, status: number, fn: () => unknown) {
  assert.throws(fn, (err: unknown) => {
    assert.ok(err instanceof HttpError, `expected HttpError, got ${err}`);
    assert.equal(err.code, code);
    assert.equal(err.status, status);
    return true;
  });
}

// ------------------------------------------------------------------ contracts

Deno.test("prayer kinds match the Swift Prayer rawValues", () => {
  assert.deepEqual([...PRAYERS], ["fajr", "dhuhr", "asr", "maghrib", "isha"]);
  assert.deepEqual([...NOTIFY_KINDS], ["post", "join", "nudge"]);
  assert.equal(prayerDisplayName("maghrib"), "Maghrib");
  assert.equal(isPrayerKind("Fajr"), false, "rawValues are lowercase");
  assert.equal(isPrayerKind("tahajjud"), false);
});

Deno.test("isDayKey accepts real yyyy-MM-dd days only", () => {
  assert.equal(isDayKey("2026-08-21"), true);
  assert.equal(isDayKey("2024-02-29"), true, "leap day");
  assert.equal(isDayKey("2026-02-30"), false);
  assert.equal(isDayKey("2026-13-01"), false);
  assert.equal(isDayKey("2026-8-21"), false, "must be zero padded");
  assert.equal(isDayKey("2026-08-21T00:00:00Z"), false);
  assert.equal(isDayKey(20260821), false);
  assert.equal(isDayKey(null), false);
});

Deno.test("isUuid rejects near-misses", () => {
  assert.equal(isUuid(USER_ID), true);
  assert.equal(isUuid(POST_ID), true, "case insensitive");
  assert.equal(isUuid("not-a-uuid"), false);
  assert.equal(isUuid(`${USER_ID} or 1=1`), false);
  assert.equal(isUuid(""), false);
  assert.equal(isUuid(undefined), false);
});

// -------------------------------------------------------------- notify bodies

Deno.test("parseNotifyRequest accepts the three documented shapes", () => {
  assert.deepEqual(parseNotifyRequest({ kind: "post", postId: POST_ID }), {
    kind: "post",
    postId: POST_ID.toLowerCase(),
  });
  assert.deepEqual(parseNotifyRequest({ kind: "join" }), { kind: "join" });
  assert.deepEqual(
    parseNotifyRequest({
      kind: "nudge",
      recipientId: USER_ID,
      dayKey: "2026-08-21",
      prayer: "asr",
    }),
    {
      kind: "nudge",
      recipientId: USER_ID,
      dayKey: "2026-08-21",
      prayer: "asr",
    },
  );
});

Deno.test("parseNotifyRequest ignores unknown/spoofed fields", () => {
  // Nothing but `kind` + the declared fields survives — a body claiming a
  // different sender or circle is simply dropped on the floor.
  assert.deepEqual(
    parseNotifyRequest({
      kind: "join",
      userId: "someone-else",
      circleId: "not-mine",
      senderId: USER_ID,
    }),
    { kind: "join" },
  );
});

Deno.test("parseNotifyRequest rejects malformed bodies", () => {
  expectHttpError("invalid_body", 400, () => parseNotifyRequest(null));
  expectHttpError("invalid_body", 400, () => parseNotifyRequest("post"));
  expectHttpError(
    "invalid_body",
    400,
    () => parseNotifyRequest([{ kind: "join" }]),
  );
  expectHttpError("invalid_kind", 400, () => parseNotifyRequest({}));
  expectHttpError(
    "invalid_kind",
    400,
    () => parseNotifyRequest({ kind: "delete" }),
  );
  expectHttpError(
    "invalid_post_id",
    400,
    () => parseNotifyRequest({ kind: "post" }),
  );
  expectHttpError(
    "invalid_post_id",
    400,
    () => parseNotifyRequest({ kind: "post", postId: 7 }),
  );
  expectHttpError(
    "invalid_recipient_id",
    400,
    () =>
      parseNotifyRequest({
        kind: "nudge",
        dayKey: "2026-08-21",
        prayer: "asr",
      }),
  );
  expectHttpError(
    "invalid_day_key",
    400,
    () =>
      parseNotifyRequest({
        kind: "nudge",
        recipientId: USER_ID,
        dayKey: "yesterday",
        prayer: "asr",
      }),
  );
  expectHttpError(
    "invalid_prayer",
    400,
    () =>
      parseNotifyRequest({
        kind: "nudge",
        recipientId: USER_ID,
        dayKey: "2026-08-21",
        prayer: "witr",
      }),
  );
});

// ------------------------------------------------------------------- retention

Deno.test("parseRetentionDays defaults to 30 and clamps the silly", () => {
  assert.equal(parseRetentionDays({}), RETENTION_DEFAULT_DAYS);
  assert.equal(parseRetentionDays(null), RETENTION_DEFAULT_DAYS);
  assert.equal(parseRetentionDays({ days: null }), RETENTION_DEFAULT_DAYS);
  assert.equal(parseRetentionDays({ days: 7 }), 7);
  assert.equal(parseRetentionDays({ days: "14" }), 14);
  assert.equal(parseRetentionDays({ days: 0 }), RETENTION_MIN_DAYS);
  assert.equal(parseRetentionDays({ days: -5 }), RETENTION_MIN_DAYS);
  assert.equal(parseRetentionDays({ days: 99_999 }), RETENTION_MAX_DAYS);
  assert.equal(parseRetentionDays({ days: 30.9 }), 30);
  expectHttpError(
    "invalid_days",
    400,
    () => parseRetentionDays({ days: "soon" }),
  );
});

Deno.test("parseRetentionMinutes defaults to an hour, allows a forced run", () => {
  assert.equal(parseRetentionMinutes({}), RETENTION_DEFAULT_MINUTES);
  assert.equal(parseRetentionMinutes({ minIntervalMinutes: 0 }), 0);
  assert.equal(parseRetentionMinutes({ minIntervalMinutes: 15 }), 15);
  assert.equal(parseRetentionMinutes({ minIntervalMinutes: -3 }), 0);
  assert.equal(
    parseRetentionMinutes({ minIntervalMinutes: 1e9 }),
    RETENTION_MAX_MINUTES,
  );
  expectHttpError(
    "invalid_min_interval",
    400,
    () => parseRetentionMinutes({ minIntervalMinutes: {} }),
  );
  assert.equal(retentionInterval(60), "60 minutes");
  assert.equal(retentionInterval(0), "0 minutes");
});

Deno.test("normalizePhotoPaths handles both PostgREST setof shapes", () => {
  assert.deepEqual(normalizePhotoPaths(null), []);
  assert.deepEqual(normalizePhotoPaths([]), []);
  assert.deepEqual(normalizePhotoPaths(["a/b/c.jpg", "d/e/f.jpg"]), [
    "a/b/c.jpg",
    "d/e/f.jpg",
  ]);
  assert.deepEqual(
    normalizePhotoPaths([{ purge_expired_photo_rows: "a/b/c.jpg" }]),
    ["a/b/c.jpg"],
  );
  assert.deepEqual(normalizePhotoPaths(["", "   ", null, 5]), []);
  assert.deepEqual(normalizePhotoPaths("solo.jpg"), ["solo.jpg"]);
});

// ------------------------------------------------------------------ copy

Deno.test("alert copy reads the way the app talks", () => {
  assert.deepEqual(postAlert({ name: "Yusuf", prayer: "fajr" }), {
    title: "📸 Yusuf posted Fajr",
    body: "Your circle is filling in.",
  });
  assert.equal(
    postAlert({ name: "Yusuf", prayer: "isha", jamaat: true }).body,
    "Prayed in jamaat 🕌",
  );
  assert.equal(
    postAlert({ name: "Yusuf", prayer: "isha", placeLabel: " Masjid " }).body,
    "At Masjid",
  );
  assert.equal(
    joinAlert({ name: "Layla" }).title,
    "Layla joined your circle 🎉",
  );
  assert.equal(
    nudgeAlert({ name: "Bilal", prayer: "maghrib" }).title,
    "👋 Bilal nudged you for Maghrib",
  );
});

Deno.test("displayName covers the bare profile row the auth trigger creates", () => {
  assert.equal(displayName(""), "Someone");
  assert.equal(displayName("   "), "Someone");
  assert.equal(displayName(null), "Someone");
  assert.equal(displayName(undefined), "Someone");
  assert.equal(displayName("  Amina "), "Amina");
  assert.equal(
    postAlert({ name: null, prayer: "asr" }).title,
    "📸 Someone posted Asr",
  );
});

Deno.test("retentionParams lets only service_role tune a destructive sweep", () => {
  const body = { days: 1, minIntervalMinutes: 0 };
  assert.deepEqual(retentionParams(body, { serviceRole: true }), {
    days: 1,
    minIntervalMinutes: 0,
  });
  // A signed-in human can trigger the sweep, but `days: 1` from them must not
  // shorten retention — they get the documented defaults instead.
  assert.deepEqual(retentionParams(body, { serviceRole: false }), {
    days: RETENTION_DEFAULT_DAYS,
    minIntervalMinutes: RETENTION_DEFAULT_MINUTES,
  });
  assert.deepEqual(retentionParams({ days: "soon" }, { serviceRole: false }), {
    days: RETENTION_DEFAULT_DAYS,
    minIntervalMinutes: RETENTION_DEFAULT_MINUTES,
  });
});

Deno.test("dayKeyWithinWindow bounds the nudge rate-limit key to the server clock", () => {
  const now = Date.parse("2026-08-21T13:00:00Z");
  assert.equal(dayKeyWithinWindow("2026-08-21", now), true);
  // ±1 day, because day_key is the client's LOCAL schedule day and a circle-mate
  // a few timezones over is legitimately on the neighbouring date.
  assert.equal(dayKeyWithinWindow("2026-08-20", now), true);
  assert.equal(dayKeyWithinWindow("2026-08-22", now), true);

  // REGRESSION: the only check on dayKey was "is this a real calendar date",
  // which accepts year 0000 to 9999. Since dayKey is part of the nudges primary
  // key — the thing §6 calls the rate limit — that is ~18 million distinct
  // tokens (3.65M days × 5 prayers) for one sender against one recipient, each
  // one a real push that does not even collapse on the lock screen.
  assert.equal(dayKeyWithinWindow("2026-08-19", now), false);
  assert.equal(dayKeyWithinWindow("2026-08-23", now), false);
  assert.equal(dayKeyWithinWindow("1000-01-02", now), false);
  assert.equal(dayKeyWithinWindow("2999-12-31", now), false);
  assert.equal(dayKeyWithinWindow("not-a-date", now), false);
});
