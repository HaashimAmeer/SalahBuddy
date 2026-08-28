// The §6 fan-out table, pinned:
//
//     post            →  relevance-filtered
//     post (reload)   →  relevance-filtered      (v5 §5)
//     join            →  never filtered
//     nudge           →  never filtered
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
  buildAPNsPayload,
  buildSilentAPNsPayload,
} from "../../supabase/functions/_shared/apns.ts";
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
/// Amina's Fajr, five minutes before Yusuf's — seeded only by `circleWith`'s
/// `secondPlace` option. Its whole job is to make `POST` not the first post in
/// its window, which is the v5 §5 path.
const EARLIER_POST = "b1000000-0000-4000-8000-000000000002";

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
///
/// `secondPlace` seeds an EARLIER post by Amina in the same window, which makes
/// Yusuf's `not_first` (v5 §5) — the only difference between the two post paths
/// is whether somebody in the circle got there first, so it is the only thing
/// the fixture changes.
function circleWith(
  phones: readonly Phone[],
  opts: { posterZone?: number | null; secondPlace?: boolean } = {},
): FakeSupabase {
  const members = [YUSUF, ...new Set(phones.map((p) => p.user))];
  const earlier: Row[] = opts.secondPlace
    ? [{
      id: EARLIER_POST,
      user_id: AMINA,
      circle_id: CIRCLE,
      day_key: DAY_KEY,
      prayer: "fajr",
      tier: "onTime",
      jamaat: false,
      place_label: null,
      utc_offset: SEATTLE,
      logged_at: "2026-08-22T11:55:00Z",
      notified_at: "2026-08-22T11:55:01Z",
    }]
    : [];
  return new FakeSupabase({
    circle_members: members.map((user_id): Row => ({
      user_id,
      circle_id: CIRCLE,
      announced_at: null,
    })),
    posts: [...earlier, {
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
  /// The `apns-push-type` each of those carried, in the same order:
  /// `"alert"` for something a person sees, `"background"` for v5 §5's
  /// reload-only push. Reading the HEADER is enough to tell the two apart
  /// because `notify/handlers.ts`'s `push` derives the header and the payload
  /// from the same `alert === null` — there is no arrangement of that function
  /// in which a background push carries a title.
  pushTypes: string[];
  /// Whether each of those payloads asked for the notification service
  /// extension (v5 §5-B's `mutable-content: 1`). Read off the built payload, so
  /// it is the fact rather than the intention.
  mutable: boolean[];
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
  const pushTypes: string[] = [];
  const mutable: boolean[] = [];
  Date.now = () => fixed;
  console.log = (...args: unknown[]) => {
    const meta = fanOutMeta(args);
    if (meta === null) return;
    fanOuts.push(meta.devices);
    pushTypes.push(meta.pushType);
    mutable.push(meta.mutableContent);
  };
  let response: Response;
  try {
    response = await handler();
  } finally {
    Date.now = realNow;
    console.log = realLog;
  }
  assert.equal(response.status, 200);
  return { body: await response.json(), fanOuts, pushTypes, mutable };
}

/// `run`, for the calls that are expected to reach APNs exactly once.
async function send(
  at: string,
  handler: () => Promise<Response>,
): Promise<{
  body: Record<string, unknown>;
  pushedTo: number;
  pushType: string;
  mutableContent: boolean;
}> {
  const { body, fanOuts, pushTypes, mutable } = await run(at, handler);
  assert.equal(
    fanOuts.length,
    1,
    `expected one APNs fan-out, saw ${fanOuts.length} — ${
      JSON.stringify(body)
    }`,
  );
  return {
    body,
    pushedTo: fanOuts[0],
    pushType: pushTypes[0],
    mutableContent: mutable[0],
  };
}

function fanOutMeta(
  args: unknown[],
): { devices: number; pushType: string; mutableContent: boolean } | null {
  if (args.length < 2 || typeof args[1] !== "string") return null;
  try {
    const meta = JSON.parse(args[1]) as Record<string, unknown> | null;
    const devices = meta?.devices;
    if (typeof devices !== "number") return null;
    const pushType = meta?.pushType;
    return {
      devices,
      pushType: typeof pushType === "string" ? pushType : "",
      mutableContent: meta?.mutableContent === true,
    };
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

Deno.test("the announcement asks the notification service extension to run", async () => {
  // v5 §5-B. `mutable-content: 1` is what gives the app ~30 seconds of
  // extension time BEFORE the banner, which is the only moment a friend's post
  // can reach a home-screen widget with the app closed. It changes nothing a
  // person sees — the extension hands `request.content` straight back — so the
  // only way to notice it is gone is a widget that never updates, on somebody
  // else's phone, days later.
  //
  // Read off the payload that was actually built for the fan-out, not off a
  // copy of the arguments: deleting `mutableContent: true` from `notifyPost`
  // has to be what fails this, and an assertion on `buildAPNsPayload` called
  // again by hand would sail straight past it.
  const db = circleWith([AMINA_PHONE]);
  const announcement = await send(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  assert.equal(announcement.mutableContent, true);
  // The push type stays `alert` — an announcement is a thing people see.
  assert.equal(announcement.pushType, "alert");

  // ...and it is per push, not something every payload picked up: a join does
  // not ask for the extension. (Nor does a nudge, which never reaches `fanOut`
  // at all.) Nothing about a widget changes when somebody is nudged, and §5-B
  // asked for the post alert.
  const join = await send(FAJR, () => notifyJoin(db.asClient(), CALLER));
  assert.equal(join.mutableContent, false);
  assert.equal(join.pushType, "alert");

  // The key itself, at the one function that can emit it — 1, not `true`:
  // Apple's `aps` dictionary takes a number here and ignores a boolean.
  const payload = buildAPNsPayload({
    alert: { title: "t", body: "b" },
    mutableContent: true,
  });
  assert.equal((payload.aps as Record<string, unknown>)["mutable-content"], 1);
});

// ------------------------------------------- v5 §5: the not_first wrinkle

Deno.test("a later post in the same window is announced QUIETLY, and never in the tray", async () => {
  // §6 pushes a banner for the FIRST post per window and nothing after it,
  // which is right for the tray and leaves a widget sitting on "3 of 5" for the
  // rest of the window. §5's answer is a second, separate push with no alert in
  // it at all: `content-available`, sent as `background`, so the phone goes and
  // looks and nobody's screen lights up.
  //
  // Amina got there five minutes earlier, so Yusuf's post is `not_first`.
  const db = circleWith([AMINA_PHONE, BILAL_PHONE, HANIF_IPAD], {
    secondPlace: true,
  });
  const { body, pushedTo, pushType, mutableContent } = await send(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );

  assert.equal(body.ok, true);
  assert.equal(body.kind, "post");
  assert.equal(
    body.reason,
    "not_first",
    "the reply still says which push this was",
  );
  assert.equal(
    pushType,
    "background",
    "a reload push sent as an alert is a banner nobody asked for",
  );
  assert.equal(
    mutableContent,
    false,
    "there is no alert here for an extension to modify",
  );

  // The reload-only payload cannot carry copy: the function that builds it
  // takes no `Alert` at all, and `push` chooses it by the ABSENCE of one — so
  // "no alert body" is a property of the shape rather than of this call.
  const quiet = buildSilentAPNsPayload({ data: { kind: "post" } });
  const aps = quiet.aps as Record<string, unknown>;
  assert.equal(aps["content-available"], 1);
  assert.equal("alert" in aps, false, "a quiet push with a body in it");
  assert.equal("sound" in aps, false);
  assert.equal("thread-id" in aps, false, "nothing to collapse into a thread");
  assert.equal("badge" in aps, false);
  assert.equal("mutable-content" in aps, false);
  assert.equal(quiet.kind, "post", "the custom data still rides along");

  // §5 keeps the collapsed tray behaviour EXACTLY as it is, which starts with
  // the alert being sent once and only once: the fan-out above is the ONLY one
  // this call made.
  assert.equal(pushedTo, 2, "Amina beside him, and the iPad with no zone");
  assert.equal(body.outOfZone, 1, "Bilal, whose clock reads 17:30");
});

Deno.test("the reload push is filtered by the same zone rule the alert is", async () => {
  // The wrong way to read "best-effort" would be "send it to everybody". A
  // phone whose own local day has already moved past this window has nothing to
  // redraw, and waking it is worse than the banner it was already spared. Same
  // three phones, same instant, one at a time — the table from the alert case,
  // reproduced for the quiet one.
  const cases: { phone: Phone; kept: number; why: string }[] = [
    { phone: AMINA_PHONE, kept: 1, why: "05:00, beside the poster" },
    { phone: BILAL_PHONE, kept: 0, why: "17:30, twelve hours past it" },
    { phone: HANIF_IPAD, kept: 1, why: "no offset — unknown is never silence" },
  ];
  for (const { phone, kept, why } of cases) {
    const db = circleWith([phone], { secondPlace: true });
    const { body, pushedTo, pushType } = await send(
      FAJR,
      () => notifyPost(db.asClient(), CALLER, POST),
    );
    assert.equal(pushType, "background", `${phone.token}: ${why}`);
    assert.equal(body.devices, kept, `${phone.token}: ${why}`);
    assert.equal(body.outOfZone, 1 - kept, `${phone.token}: ${why}`);
    assert.equal(pushedTo, kept, `${phone.token}: ${why}`);
  }
});

Deno.test("the reload push is NOT gated on the friend-activity toggle, and the alert still is", async () => {
  // The one place the two post paths deliberately disagree, and the reasoning
  // is the toggle's own copy: "Friend activity — when someone in your circle
  // posts first" is a preference about being BUZZED, and it is OFF by default.
  // Apply it to a push that shows nothing and the widget of everybody who never
  // turned it on — i.e. almost everybody — goes stale for the rest of every
  // window, which is the exact failure §5 exists to fix. The quiet push carries
  // nothing the recipient's own next pull would not fetch anyway.
  //
  // Salma is standing beside the poster, so nothing about WHERE she is can
  // account for a difference.
  const loud = circleWith([AMINA_PHONE, SALMA_PHONE]);
  const announcement = await send(
    FAJR,
    () => notifyPost(loud.asClient(), CALLER, POST),
  );
  assert.equal(announcement.body.devices, 1, "Amina only — Salma opted out");

  const quiet = circleWith([AMINA_PHONE, SALMA_PHONE], { secondPlace: true });
  const reload = await send(
    FAJR,
    () => notifyPost(quiet.asClient(), CALLER, POST),
  );
  assert.equal(reload.body.reason, "not_first");
  assert.equal(reload.body.devices, 2, "Salma's widget is stale too");
  assert.equal(reload.pushedTo, 2);

  // The toggle is a WHERE clause, so the difference is visible in the traffic
  // and not only in the counts: the quiet lookup carries no
  // `notify_friend_activity` filter at all.
  assert.deepEqual(deviceLookups(loud).map((q) => q.filters), [
    [`user_id=in.(${AMINA},${SALMA})`, "notify_friend_activity=eq.true"],
  ]);
  assert.deepEqual(deviceLookups(quiet).map((q) => q.filters), [
    [`user_id=in.(${AMINA},${SALMA})`],
  ]);
});

Deno.test("one notification per post, whichever kind it turned out to be", async () => {
  // The lease used to be claimed only on the announcement path, because a
  // `not_first` post returned before reaching it. Now that the quiet push
  // exists, an unleased second path would be a fan-out any member could trigger
  // in a loop from a phone — and a silent one, so nobody would notice it
  // happening. `claimPostNotification` therefore covers both, which is why it
  // moved above the first-post check.
  const db = circleWith([AMINA_PHONE], { secondPlace: true });

  const first = await send(FAJR, () => notifyPost(db.asClient(), CALLER, POST));
  assert.equal(first.body.reason, "not_first");
  assert.equal(first.pushedTo, 1);
  assert.notEqual(
    db.table("posts").find((row) => row.id === POST)?.notified_at,
    null,
    "the quiet push has to spend the lease, or it is unbounded",
  );

  const again = await run(FAJR, () => notifyPost(db.asClient(), CALLER, POST));
  assert.equal(again.body.reason, "already_notified");
  assert.deepEqual(again.fanOuts, [], "no second reload");
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
