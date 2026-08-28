// The §6 fan-out table, pinned:
//
//     post   →  relevance-filtered
//     join   →  never filtered
//     nudge  →  never filtered
//
// Until now nothing enforced the second and third rows but the absence of an
// argument at two call sites. `zones_test.ts` proves the FILTER is right —
// which recipient a window keeps, and why a 15-minute offset can decide it —
// and says nothing about who the filter is pointed at. This file is the other
// half: it drives all three handlers through a fake Supabase client, with the
// same three phones in the same three places every time, and reads how many
// devices each push actually reached.
//
// The journey behind the numbers is one circle: Yusuf logs Fajr at 05:00 in
// Seattle. Amina is beside him. Bilal is in Mumbai, where it is 17:30 on the
// SAME CALENDAR DATE — the case a date-only rule waves through and a comparison
// of local clock readings catches (SPEC-V4 §6, and `STALE_AFTER_SECONDS` in
// `_shared/zones.ts`, which is where the four-hour tolerance and the reason it
// is one-directional are written down). Hanif's iPad registered before the
// offset column existed and has never said where it is.
//
// APNs is deliberately unconfigured here (no key, and no --allow-env to read
// one), so nothing leaves the process: `deliverToDevices` counts the devices it
// was handed and log-and-skips.

import assert from "node:assert/strict";
import {
  type Caller,
  notifyJoin,
  notifyNudge,
  notifyPost,
} from "../../supabase/functions/notify/handlers.ts";
import type { NotifyRequest } from "../../supabase/functions/_shared/validate.ts";
import { parseNotifyRequest } from "../../supabase/functions/_shared/validate.ts";
import { FakeSupabase, type RecordedQuery, type Row } from "./fake_supabase.ts";

// Real uuids, because the nudge request goes through the real `parseNotifyRequest`
// rather than being hand-built — the handler should be fed what the endpoint
// would feed it.
const CIRCLE = "c1000000-0000-4000-8000-000000000001";
const YUSUF = "a1000000-0000-4000-8000-000000000001"; // the poster, in Seattle
const AMINA = "a1000000-0000-4000-8000-000000000002"; // Seattle too
const BILAL = "a1000000-0000-4000-8000-000000000003"; // Mumbai, +5:30
const HANIF = "a1000000-0000-4000-8000-000000000004"; // an iPad with no offset
const SALMA = "a1000000-0000-4000-8000-000000000005"; // Seattle, friend activity OFF
const POST = "b1000000-0000-4000-8000-000000000001";

const SEATTLE = -7 * 3600; // PDT
const MUMBAI = 5 * 3600 + 30 * 60; // IST, a half-hour zone

/// 05:00 in Seattle. 17:30 in Mumbai, on the same date.
const FAJR = "2026-08-22T12:00:00Z";
const DAY_KEY = "2026-08-22";

const CALLER: Caller = {
  callerId: YUSUF,
  circleId: CIRCLE,
  senderName: "Yusuf",
};

interface Phone {
  user: string;
  token: string;
  /// Seconds east of UTC, or null for a device that has never said.
  zone: number | null;
  /// §6's friend-activity opt-in, off by default in the DB and set from
  /// `AppSettings`. On for every phone but SALMA_PHONE, so that in the tests
  /// about zones the relevance rule is the only thing that can move a count.
  friendActivity: boolean;
}

function phone(
  user: string,
  token: string,
  zone: number | null,
  friendActivity = true,
): Phone {
  return { user, token, zone, friendActivity };
}

const AMINA_PHONE = phone(AMINA, "amina-phone", SEATTLE);
const BILAL_PHONE = phone(BILAL, "bilal-phone", MUMBAI);
const HANIF_IPAD = phone(HANIF, "hanif-ipad", null);
/// Beside the poster, so nothing about WHERE she is can drop her — the only
/// thing that can is the toggle.
const SALMA_PHONE = phone(SALMA, "salma-phone", SEATTLE, false);

/// Yusuf's circle, his 05:00 Fajr already in `posts`, and one device row per
/// phone. `posterZone` is the post's own `utc_offset` — nullable forever, and
/// null there means "filter nobody".
function circleWith(
  phones: readonly Phone[],
  opts: { posterZone?: number | null } = {},
): FakeSupabase {
  const members = [YUSUF, ...new Set(phones.map((p) => p.user))];
  return new FakeSupabase({
    circle_members: members.map((user_id): Row => ({
      user_id,
      circle_id: CIRCLE,
      announced_at: null,
    })),
    posts: [{
      id: POST,
      user_id: YUSUF,
      circle_id: CIRCLE,
      day_key: DAY_KEY,
      prayer: "fajr",
      tier: "onTime",
      jamaat: false,
      place_label: null,
      utc_offset: opts.posterZone === undefined ? SEATTLE : opts.posterZone,
      logged_at: FAJR,
      notified_at: null,
    }],
    devices: phones.map((p, index): Row => ({
      user_id: p.user,
      apns_token: p.token,
      environment: "production",
      notify_friend_activity: p.friendActivity,
      utc_offset: p.zone,
      updated_at: `2026-08-22T00:00:0${index}Z`,
    })),
  });
}

interface Sent {
  body: Record<string, unknown>;
  /// Every APNs fan-out the call made, as device counts.
  fanOuts: number[];
}

/// Runs one handler with the server clock pinned.
///
/// These handlers read `Date.now()` directly — they are server code, not the
/// app, so there is no `AppClock` here — and the whole relevance decision is a
/// comparison of clock readings. The instant therefore has to be a fact of the
/// test rather than of the afternoon it happens to run on.
///
/// The device counts come out of `deliverToDevices`'s "not configured" log
/// line, which is the only place a NUDGE's count exists at all: `countsPrivate`
/// keeps `devices`/`outOfZone` out of that reply on purpose, because how many
/// live registrations one named person has is not another member's business.
/// The reading is structural — a meta object carrying a numeric `devices` —
/// rather than a match on the message, so rewording the log does not break it.
async function run(
  at: string,
  handler: () => Promise<Response>,
): Promise<Sent> {
  const realNow = Date.now;
  const realLog = console.log;
  const fixed = Date.parse(at);
  assert.ok(!Number.isNaN(fixed), `bad instant in test: ${at}`);
  const fanOuts: number[] = [];
  Date.now = () => fixed;
  console.log = (...args: unknown[]) => {
    const count = fanOutSize(args);
    if (count !== null) fanOuts.push(count);
  };
  let response: Response;
  try {
    response = await handler();
  } finally {
    Date.now = realNow;
    console.log = realLog;
  }
  assert.equal(response.status, 200);
  return { body: await response.json(), fanOuts };
}

/// `run`, for the calls that are expected to reach APNs exactly once.
async function send(
  at: string,
  handler: () => Promise<Response>,
): Promise<{ body: Record<string, unknown>; pushedTo: number }> {
  const { body, fanOuts } = await run(at, handler);
  assert.equal(
    fanOuts.length,
    1,
    `expected one APNs fan-out, saw ${fanOuts.length} — ${
      JSON.stringify(body)
    }`,
  );
  return { body, pushedTo: fanOuts[0] };
}

function fanOutSize(args: unknown[]): number | null {
  if (args.length < 2 || typeof args[1] !== "string") return null;
  try {
    const meta = JSON.parse(args[1]) as Record<string, unknown> | null;
    const devices = meta?.devices;
    return typeof devices === "number" ? devices : null;
  } catch {
    return null;
  }
}

/// Every `devices` lookup a call made, in order. Both §6 opt-ins are applied in
/// the QUERY rather than to its answer, so which of them a handler asked for is
/// visible here and not only in the counts.
function deviceLookups(db: FakeSupabase): RecordedQuery[] {
  return db.queries.filter((q) => q.table === "devices" && q.op === "select");
}

function nudgeFor(
  recipientId: string,
  prayer: string,
): Extract<NotifyRequest, { kind: "nudge" }> {
  const request = parseNotifyRequest({
    kind: "nudge",
    recipientId,
    dayKey: DAY_KEY,
    prayer,
  });
  assert.equal(request.kind, "nudge");
  return request as Extract<NotifyRequest, { kind: "nudge" }>;
}

// ------------------------------------------------------------------- posts

Deno.test("a post is announced where the morning still is, and not where the evening has come", async () => {
  // THE case, end to end. Bilal is on the same calendar date as the post, so
  // only the clock-reading half of the rule can drop him: strip `logged_at`
  // from the window and this test goes to three.
  const db = circleWith([AMINA_PHONE, BILAL_PHONE, HANIF_IPAD]);
  const { body, pushedTo } = await send(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  assert.equal(body.ok, true);
  assert.equal(body.kind, "post");
  assert.equal(body.devices, 2, "Amina beside him, and the iPad with no zone");
  assert.equal(body.outOfZone, 1, "Bilal, whose clock reads 17:30");
  assert.equal(pushedTo, 2, "and only those two were handed to APNs");
});

Deno.test("and it is the evening that is dropped, one phone at a time", async () => {
  // Names which phone the counts above belong to — two out of three could
  // otherwise be any two — and pins the third rule of §6 while it is here:
  // a device that has never said where it is is ALWAYS notified.
  const cases: { phone: Phone; kept: number; why: string }[] = [
    { phone: AMINA_PHONE, kept: 1, why: "05:00, beside the poster" },
    { phone: BILAL_PHONE, kept: 0, why: "17:30, twelve hours past it" },
    { phone: HANIF_IPAD, kept: 1, why: "no offset — unknown is never silence" },
  ];
  for (const { phone, kept, why } of cases) {
    const db = circleWith([phone]);
    const { body, pushedTo } = await send(
      FAJR,
      () => notifyPost(db.asClient(), CALLER, POST),
    );
    assert.equal(body.devices, kept, `${phone.token}: ${why}`);
    assert.equal(body.outOfZone, 1 - kept, `${phone.token}: ${why}`);
    assert.equal(pushedTo, kept, `${phone.token}: ${why}`);
  }
});

Deno.test("a post whose poster never said where they were filters nobody", async () => {
  // `posts.utc_offset` is nullable forever — every row written before
  // 20260822000200 has no answer. With no idea where the post came from there
  // is no way to tell a Mumbai evening from a Seattle midnight, so the window
  // is null and the whole circle hears it.
  const db = circleWith([AMINA_PHONE, BILAL_PHONE, HANIF_IPAD], {
    posterZone: null,
  });
  const { body, pushedTo } = await send(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  assert.equal(body.devices, 3);
  assert.equal(body.outOfZone, 0);
  assert.equal(pushedTo, 3);
});

// -------------------------------------------------------------------- joins

Deno.test("a join reaches the whole circle, including the phone a post was stale for", async () => {
  // Same three phones, same instant, same everything — the ONLY difference is
  // which handler ran. "Yusuf joined your circle" is not about a day, so there
  // is no day for Bilal's own to have moved past. Add a `relevance` to
  // `notifyJoin` and this drops to two.
  const db = circleWith([AMINA_PHONE, BILAL_PHONE, HANIF_IPAD]);
  const { body, pushedTo } = await send(
    FAJR,
    () => notifyJoin(db.asClient(), CALLER),
  );
  assert.equal(body.ok, true);
  assert.equal(body.kind, "join");
  assert.equal(body.devices, 3);
  assert.equal(body.outOfZone, 0, "nothing was judged, so nothing was dropped");
  assert.equal(pushedTo, 3);
});

// ------------------------------------------- the other call-site-only rule

Deno.test("the friend-activity toggle is a post's business, and not a join's", async () => {
  // §6's SECOND opt-in, and it lives in the same object literal as `relevance`,
  // set by the same one call site and by no type: `notifyPost` passes
  // `friendActivityOnly: true` to `fanOut` and `notifyJoin` deliberately does
  // not. "Yusuf posted first for Fajr" is friend activity; "Yusuf joined your
  // circle" is a circle event, which is why the same phone answers differently
  // to the two.
  //
  // Salma is standing beside the poster, so nothing about WHERE she is can
  // account for her being dropped. Delete `friendActivityOnly` from
  // `notifyPost` and the post below goes to two — which in production means
  // pushing friend activity to somebody who turned it off, and iOS cannot
  // suppress an alert it has already been handed.
  const db = circleWith([AMINA_PHONE, SALMA_PHONE]);

  const post = await send(FAJR, () => notifyPost(db.asClient(), CALLER, POST));
  assert.equal(post.body.devices, 1, "Amina only — Salma opted out");
  assert.equal(post.body.outOfZone, 0, "and not for being in the wrong hour");
  assert.equal(post.pushedTo, 1);

  const join = await send(FAJR, () => notifyJoin(db.asClient(), CALLER));
  assert.equal(join.body.devices, 2, "a join is not friend activity");
  assert.equal(join.pushedTo, 2, "Salma's phone included");

  // The toggle is a WHERE clause, so an opted-out device is never fetched at
  // all — it cannot be counted as out-of-zone, or handed to APNs by a later
  // edit that forgets why the list was short.
  assert.deepEqual(deviceLookups(db).map((q) => q.filters), [
    [`user_id=in.(${AMINA},${SALMA})`, "notify_friend_activity=eq.true"],
    [`user_id=in.(${AMINA},${SALMA})`],
  ]);
});

// ------------------------------------------------------------------- nudges

Deno.test("a nudge reaches the one person it was aimed at, however far past their evening", async () => {
  // Bilal is exactly the phone the post filter dropped, at exactly the same
  // instant. A nudge is one human deliberately picking one name out of a grid;
  // dropping it for being "stale" would break the only push in §6 somebody
  // meant to send. Route this through `fanOut`, or partition inside
  // `notifyNudge`, and the count goes to zero.
  const db = circleWith([AMINA_PHONE, BILAL_PHONE, HANIF_IPAD]);
  db.rpcResults.set("record_nudge", { data: true, error: null });

  const { body, pushedTo } = await send(
    FAJR,
    () =>
      notifyNudge(
        db.asClient(),
        () => db.asClient(),
        CALLER,
        nudgeFor(BILAL, "fajr"),
      ),
  );
  assert.equal(body.ok, true);
  assert.equal(body.kind, "nudge");
  assert.equal(pushedTo, 1, "Bilal's phone, in Mumbai at 17:30");

  // The reply is deliberately count-free: the numbers below are about one named
  // person, so §6 keeps them out of another member's answer.
  assert.equal("devices" in body, false);
  assert.equal("outOfZone" in body, false);
  assert.equal("delivered" in body, false);

  // ...and the shape of the traffic says the same thing the count does: one
  // devices lookup, scoped to Bilal and carrying no `notify_friend_activity`
  // clause (a nudge is a person, not friend activity), and the circle was never
  // enumerated for a fan-out (`user_id=neq.` is `circleMemberIds` excluding the
  // sender, which only `fanOut` issues).
  assert.deepEqual(deviceLookups(db).map((q) => q.filters), [[
    `user_id=in.(${BILAL})`,
  ]]);
  assert.equal(
    db.queries.some((q) =>
      q.filters.some((filter) => filter.startsWith("user_id=neq."))
    ),
    false,
    "a nudge went through the circle fan-out",
  );

  // The rate limit is the sender's, derived from auth.uid() inside the RPC —
  // the body only ever says who to reach.
  assert.deepEqual(db.rpcCalls, [{
    fn: "record_nudge",
    args: { p_recipient: BILAL, p_day_key: DAY_KEY, p_prayer: "fajr" },
  }]);
});

Deno.test("a rate-limited nudge never reaches APNs at all", async () => {
  // `record_nudge` answering false is not an error — it is "they were already
  // nudged for this window", and nobody's phone buzzes twice.
  const db = circleWith([BILAL_PHONE]);
  db.rpcResults.set("record_nudge", { data: false, error: null });

  const { body, fanOuts } = await run(
    FAJR,
    () =>
      notifyNudge(
        db.asClient(),
        () => db.asClient(),
        CALLER,
        nudgeFor(BILAL, "fajr"),
      ),
  );
  assert.equal(body.sent, false);
  assert.equal(body.reason, "rate_limited");
  assert.deepEqual(fanOuts, []);
});

// -------------------------------------------------------------- the leases

Deno.test("each announcement is claimed exactly once", async () => {
  // Both fan-outs are stateless apart from their lease, so a client POSTing the
  // same body in a loop is only ever one push. Checked here because the lease
  // and the relevance rule are the two things a refactor of these handlers can
  // quietly drop.
  const db = circleWith([AMINA_PHONE]);

  const first = await send(FAJR, () => notifyPost(db.asClient(), CALLER, POST));
  assert.equal(first.body.sent, false, "APNs is unconfigured in this suite");
  assert.equal(first.pushedTo, 1);
  const second = await run(FAJR, () => notifyPost(db.asClient(), CALLER, POST));
  assert.equal(second.body.reason, "already_notified");
  assert.deepEqual(second.fanOuts, [], "no second announcement");
  assert.notEqual(db.table("posts")[0].notified_at, null);

  const joined = await send(FAJR, () => notifyJoin(db.asClient(), CALLER));
  assert.equal(joined.pushedTo, 1);
  const again = await run(FAJR, () => notifyJoin(db.asClient(), CALLER));
  assert.equal(again.body.reason, "already_announced");
  assert.deepEqual(again.fanOuts, []);
});

Deno.test("a post that is not the caller's is not announceable", async () => {
  // Ownership is the DB's answer, not the body's — the handler re-derives it
  // from the row rather than trusting the postId it was handed.
  const db = circleWith([AMINA_PHONE]);
  const stranger: Caller = { ...CALLER, callerId: BILAL };
  const { body, fanOuts } = await run(
    FAJR,
    () => notifyPost(db.asClient(), stranger, POST),
  );
  assert.equal(body.reason, "post_not_found");
  assert.deepEqual(fanOuts, []);
  assert.equal(
    db.table("posts")[0].notified_at,
    null,
    "the lease is untouched",
  );
});
