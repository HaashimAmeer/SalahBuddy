// SPEC-V5 §6 — the Live Activity half of `notify`, pinned.
//
// Three separable claims, and this file keeps them separate on purpose because
// each one dies a different way:
//
//   1. **The topic.** §1 named it: "`sendAPNs` already takes a push type. Live
//      Activities need a different `apns-topic` suffix, and that's the only
//      line that assumes a bare bundle id." Send a liveactivity push to the
//      bare id and Apple answers 400/TopicDisallowed — a failure that looks,
//      from the outside, exactly like a key that was never configured.
//   2. **The payload.** ActivityKit decodes `content-state` on the device with
//      no reply of any kind. A wrong shape is not an error; it is a push that
//      does nothing, forever, silently. And a payload one byte over 4 KB is
//      rejected WHOLE rather than truncated, which is why the trimming here is
//      about which fields survive rather than about a cap.
//   3. **The routing.** Which activities a post is allowed to move: this
//      window's and no other, everybody but the poster, nobody whose local day
//      has moved past it, and never a push-to-start token.
//
// As in `notify_test.ts`, APNs is deliberately unconfigured (no key, no
// --allow-env), so nothing leaves the process: `deliverToDevices` counts what
// it was handed, logs one structured line and skips. That line is where the
// per-fan-out numbers below come from.

import assert from "node:assert/strict";
import {
  APNS_ALERT_PRIORITY,
  APNS_BACKGROUND_PUSH_TYPE,
  APNS_LIVE_ACTIVITY_PRIORITY,
  APNS_LIVE_ACTIVITY_PUSH_TYPE,
  APNS_LIVE_ACTIVITY_TOPIC_SUFFIX,
  apnsPayloadBytes,
  apnsTopic,
  buildLiveActivityPayload,
  fitsLiveActivityBudget,
  LIVE_ACTIVITY_PAYLOAD_LIMIT,
} from "../../supabase/functions/_shared/apns.ts";
import {
  buildLiveActivityAttributes,
  buildLiveActivityContentState,
  buildLiveActivityPush,
  LIVE_ACTIVITY_ATTRIBUTES_TYPE,
  LIVE_ACTIVITY_FACE_CAP,
  type LiveActivityFace,
} from "../../supabase/functions/_shared/liveactivity.ts";
import { type Caller, notifyPost } from "../../supabase/functions/notify/handlers.ts";
import { FakeSupabase, type Row } from "./fake_supabase.ts";

// ------------------------------------------------------------------- the topic

Deno.test("an ordinary push still addresses the bare bundle id", () => {
  assert.equal(apnsTopic("org.amacvoters.salahbuddymock"), "org.amacvoters.salahbuddymock");
  assert.equal(
    apnsTopic("org.amacvoters.salahbuddymock", "alert"),
    "org.amacvoters.salahbuddymock",
  );
  assert.equal(
    apnsTopic("org.amacvoters.salahbuddymock", APNS_BACKGROUND_PUSH_TYPE),
    "org.amacvoters.salahbuddymock",
  );
});

Deno.test("a liveactivity push addresses the suffixed topic", () => {
  assert.equal(
    apnsTopic("org.amacvoters.salahbuddymock", APNS_LIVE_ACTIVITY_PUSH_TYPE),
    `org.amacvoters.salahbuddymock${APNS_LIVE_ACTIVITY_TOPIC_SUFFIX}`,
  );
});

Deno.test("a bundle id that already carries the suffix is not suffixed twice", () => {
  // APNS_BUNDLE_ID is a deployment secret set by a human who may well have read
  // Apple's docs first. Two suffixes is a silent 400 on every activity push.
  const already = `org.amacvoters.salahbuddymock${APNS_LIVE_ACTIVITY_TOPIC_SUFFIX}`;
  assert.equal(apnsTopic(already, APNS_LIVE_ACTIVITY_PUSH_TYPE), already);
});

// ----------------------------------------------------------------- the payload

const STATE = buildLiveActivityContentState({
  prayedCount: 3,
  memberCount: 5,
  youLogged: false,
  faces: [{ name: "Mina", emoji: "🌸", tier: "onTime" }],
  updatedAtSeconds: 1_756_000_000,
});

Deno.test("an update payload carries the event, the timestamp and the state", () => {
  const payload = buildLiveActivityPayload({
    event: "update",
    contentState: STATE,
    timestampSeconds: 1_756_000_000,
    staleSeconds: 1_756_003_600,
  });
  const aps = payload.aps as Record<string, unknown>;
  assert.equal(aps.event, "update");
  assert.equal(aps.timestamp, 1_756_000_000);
  assert.equal(aps["stale-date"], 1_756_003_600);
  assert.deepEqual(aps["content-state"], STATE);
  // Attributes belong to a START and nothing else — sending them on an update
  // is how you find out ActivityKit ignores the whole push.
  assert.equal(aps["attributes-type"], undefined);
  assert.equal(aps.attributes, undefined);
  // And a dismissal date means nothing on a running activity.
  assert.equal(aps["dismissal-date"], undefined);
});

Deno.test("an end payload is the only one that may set a dismissal date", () => {
  const ending = buildLiveActivityPayload({
    event: "end",
    contentState: STATE,
    timestampSeconds: 1_756_000_000,
    dismissalSeconds: 1_756_000_300,
  });
  assert.equal(
    (ending.aps as Record<string, unknown>)["dismissal-date"],
    1_756_000_300,
  );
  const updating = buildLiveActivityPayload({
    event: "update",
    contentState: STATE,
    timestampSeconds: 1_756_000_000,
    dismissalSeconds: 1_756_000_300,
  });
  assert.equal(
    (updating.aps as Record<string, unknown>)["dismissal-date"],
    undefined,
  );
});

Deno.test("a start payload without attributes is refused here, not by Apple", () => {
  assert.throws(() =>
    buildLiveActivityPayload({
      event: "start",
      contentState: STATE,
      timestampSeconds: 1_756_000_000,
    })
  );
  const started = buildLiveActivityPayload({
    event: "start",
    contentState: STATE,
    timestampSeconds: 1_756_000_000,
    attributesType: LIVE_ACTIVITY_ATTRIBUTES_TYPE,
    attributes: buildLiveActivityAttributes({
      prayer: "asr",
      dayKey: "2026-08-28",
      endsAtSeconds: 1_756_003_600,
    }),
  });
  const aps = started.aps as Record<string, unknown>;
  assert.equal(aps["attributes-type"], "PrayerWindowAttributes");
  assert.deepEqual(aps.attributes, {
    prayer: "asr",
    dayKey: "2026-08-28",
    endsAt: 1_756_003_600,
  });
});

Deno.test("nothing in the content state is a date", () => {
  // Two JSON decoders we do not control sit on either side of this wire, and a
  // date strategy they have to agree on is an agreement that holds until an OS
  // update. Everything temporal is a number of seconds.
  assert.equal(typeof STATE.updatedAt, "number");
  const attributes = buildLiveActivityAttributes({
    prayer: "asr",
    dayKey: "2026-08-28",
    endsAtSeconds: 1_756_003_600.9,
  });
  assert.equal(typeof attributes.endsAt, "number");
  assert.equal(attributes.endsAt, 1_756_003_600, "seconds, floored");
});

Deno.test("the face list is capped at what the row draws", () => {
  const many: LiveActivityFace[] = Array.from({ length: 9 }, (_, i) => ({
    name: `Friend ${i}`,
    emoji: "🙂",
    tier: "prayed",
  }));
  const state = buildLiveActivityContentState({
    prayedCount: 9,
    memberCount: 9,
    youLogged: true,
    faces: many,
    updatedAtSeconds: 0,
  });
  assert.equal(state.faces.length, LIVE_ACTIVITY_FACE_CAP);
  // ...and the COUNT is untouched by the cap: "9 of 9 prayed" is still true.
  assert.equal(state.prayedCount, 9);
});

Deno.test("counts never go negative and never invert into a ring past full", () => {
  const state = buildLiveActivityContentState({
    prayedCount: -2,
    memberCount: 0,
    youLogged: false,
    updatedAtSeconds: 0,
  });
  assert.equal(state.prayedCount, 0);
  assert.equal(state.memberCount, 0);
});

Deno.test("an oversized payload drops faces, never the counts", () => {
  // A name is user-supplied text of unbounded length, so the face CAP does not
  // bound the bytes. Four very long names in a script where a glyph costs four
  // UTF-8 bytes is a payload Apple rejects whole — and the counts, which are
  // the point of the whole surface, are what must survive.
  const huge: LiveActivityFace[] = Array.from({ length: 4 }, (_, i) => ({
    name: "م".repeat(900) + i,
    emoji: "🌙",
    tier: "onTime",
  }));
  const built = buildLiveActivityPush({
    event: "update",
    contentState: buildLiveActivityContentState({
      prayedCount: 4,
      memberCount: 6,
      youLogged: false,
      faces: huge,
      updatedAtSeconds: 1_756_000_000,
    }),
    timestampSeconds: 1_756_000_000,
  });
  assert.ok(built.facesDropped > 0, "an over-budget payload went out unchanged");
  assert.ok(
    built.bytes <= LIVE_ACTIVITY_PAYLOAD_LIMIT,
    `trimmed payload is still ${built.bytes} bytes`,
  );
  assert.ok(fitsLiveActivityBudget(built.payload));
  const state = (built.payload.aps as Record<string, unknown>)["content-state"] as
    Record<string, unknown>;
  assert.equal(state.prayedCount, 4);
  assert.equal(state.memberCount, 6);
});

Deno.test("an ordinary circle loses no faces at all", () => {
  const built = buildLiveActivityPush({
    event: "update",
    contentState: buildLiveActivityContentState({
      prayedCount: 4,
      memberCount: 5,
      youLogged: true,
      faces: [
        { name: "Mina", emoji: "🌸", tier: "onTime" },
        { name: "Yusuf", emoji: "🧢", tier: "prayed" },
        { name: "Harun", emoji: "🎧", tier: "lastCall" },
        { name: "Sara", emoji: "🌙", tier: "qada" },
      ],
      updatedAtSeconds: 1_756_000_000,
    }),
    timestampSeconds: 1_756_000_000,
  });
  assert.equal(built.facesDropped, 0);
  assert.ok(apnsPayloadBytes(built.payload) < 1024, "a normal push is tiny");
});

// ----------------------------------------------------------------- the routing

const CIRCLE = "c1000000-0000-4000-8000-000000000001";
const YUSUF = "a1000000-0000-4000-8000-000000000001"; // the poster, Seattle
const AMINA = "a1000000-0000-4000-8000-000000000002"; // Seattle, has an activity
const BILAL = "a1000000-0000-4000-8000-000000000003"; // Mumbai, +5:30
const HANIF = "a1000000-0000-4000-8000-000000000004"; // an isha activity
const POST = "b1000000-0000-4000-8000-000000000001";

const SEATTLE = -7 * 3600;
const MUMBAI = 5 * 3600 + 30 * 60;
/// 05:00 in Seattle; 17:30 in Mumbai on the SAME calendar date, which is the
/// case the zone filter exists for (see zones_test.ts).
const FAJR = "2026-08-22T12:00:00Z";
const DAY_KEY = "2026-08-22";
const WINDOW_END = "2026-08-22T13:00:00Z";

const CALLER: Caller = { callerId: YUSUF, circleId: CIRCLE, senderName: "Yusuf" };

interface TokenSeed {
  user: string;
  token: string;
  kind: "start" | "update";
  prayer?: string;
  endsAt?: string | null;
  zone?: number | null;
}

function circleWith(tokens: readonly TokenSeed[]): FakeSupabase {
  const members = [YUSUF, AMINA, BILAL, HANIF];
  return new FakeSupabase({
    circle_members: members.map((user_id): Row => ({
      user_id,
      circle_id: CIRCLE,
      announced_at: "2026-08-01T00:00:00Z",
    })),
    profiles: members.map((id, i): Row => ({
      id,
      name: ["Yusuf", "Amina", "Bilal", "Hanif"][i],
      avatar_emoji: ["🧢", "🌸", "🎧", "🌙"][i],
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
      utc_offset: SEATTLE,
      logged_at: FAJR,
      notified_at: null,
    }],
    // No `devices` rows at all: the alert and reload fan-outs then reach nobody
    // and every fan-out this file counts is a Live Activity one.
    devices: [],
    live_activity_tokens: tokens.map((seed, index): Row => ({
      token: seed.token,
      user_id: seed.user,
      kind: seed.kind,
      day_key: seed.kind === "update" ? DAY_KEY : null,
      prayer: seed.kind === "update" ? (seed.prayer ?? "fajr") : null,
      ends_at: seed.endsAt === undefined ? WINDOW_END : seed.endsAt,
      environment: "production",
      utc_offset: seed.zone === undefined ? SEATTLE : seed.zone,
      updated_at: `2026-08-22T00:00:0${index}Z`,
    })),
  });
}

interface Fan {
  devices: number;
  pushType: string;
  priority: number;
}

/// One structured fan-out log line, or null. Read as an OBJECT with named keys
/// rather than by matching the sentence, so rewording the log does not break
/// the test (the same contract `notify_test.ts` relies on).
function fanOutMeta(args: readonly unknown[]): Fan | null {
  if (args.length < 2 || typeof args[1] !== "string") return null;
  let meta: unknown;
  try {
    meta = JSON.parse(args[1]);
  } catch {
    return null;
  }
  if (meta === null || typeof meta !== "object") return null;
  const record = meta as Record<string, unknown>;
  if (typeof record.devices !== "number") return null;
  return {
    devices: record.devices,
    pushType: String(record.pushType ?? "alert"),
    priority: Number(record.priority ?? APNS_ALERT_PRIORITY),
  };
}

async function run(
  at: string,
  handler: () => Promise<Response>,
): Promise<{ body: Record<string, unknown>; fans: Fan[] }> {
  const realNow = Date.now;
  const realLog = console.log;
  const fixed = Date.parse(at);
  assert.ok(!Number.isNaN(fixed), `bad instant in test: ${at}`);
  const fans: Fan[] = [];
  Date.now = () => fixed;
  console.log = (...args: unknown[]) => {
    const meta = fanOutMeta(args);
    if (meta !== null) fans.push(meta);
  };
  try {
    const response = await handler();
    return { body: await response.json(), fans };
  } finally {
    Date.now = realNow;
    console.log = realLog;
  }
}

function liveActivityCounts(body: Record<string, unknown>): Record<string, number> {
  const counts = body.liveActivity;
  assert.ok(counts && typeof counts === "object", "no liveActivity in the reply");
  return counts as Record<string, number>;
}

Deno.test("this window's activities are moved, and every other one is left alone", async () => {
  const db = circleWith([
    { user: AMINA, token: "amina-activity", kind: "update" },
    // A different window on the same day. Pushing it would overwrite an isha
    // activity's content state with fajr's counts.
    { user: HANIF, token: "hanif-isha", kind: "update", prayer: "isha" },
    // Registered, and deliberately never spent — see `liveActivityForPost`.
    { user: AMINA, token: "amina-start", kind: "start" },
  ]);
  const { body, fans } = await run(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );

  const activity = fans.filter((f) => f.pushType === APNS_LIVE_ACTIVITY_PUSH_TYPE);
  assert.equal(activity.length, 1, "expected exactly one live activity fan-out");
  assert.equal(activity[0].devices, 1, "only Amina's fajr activity");
  assert.equal(activity[0].priority, APNS_LIVE_ACTIVITY_PRIORITY);

  const counts = liveActivityCounts(body);
  assert.equal(counts.tokens, 1);
  assert.equal(counts.updated, 1);
  assert.equal(counts.ended, 0);
  assert.equal(counts.outOfZone, 0);

  // Nothing was deleted: a running activity keeps its token.
  assert.equal(db.table("live_activity_tokens").length, 3);
});

Deno.test("the poster's own activity is never pushed", async () => {
  // Their phone is running at that instant and moves its own activity through
  // the same publishWidgetSnapshot path that writes widget.json — the app is
  // the writer, on its own device (§3).
  const db = circleWith([
    { user: YUSUF, token: "yusuf-activity", kind: "update" },
  ]);
  const { body, fans } = await run(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  assert.equal(
    fans.filter((f) => f.pushType === APNS_LIVE_ACTIVITY_PUSH_TYPE).length,
    0,
  );
  assert.equal(liveActivityCounts(body).tokens, 0);
});

Deno.test("a push-to-start token is stored and never spent", async () => {
  const db = circleWith([
    { user: AMINA, token: "amina-start", kind: "start" },
    { user: BILAL, token: "bilal-start", kind: "start", zone: MUMBAI },
  ]);
  const { body, fans } = await run(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  assert.equal(
    fans.filter((f) => f.pushType === APNS_LIVE_ACTIVITY_PUSH_TYPE).length,
    0,
    "a start token was spent — see backend/README.md, 'Who starts a Live Activity'",
  );
  assert.equal(liveActivityCounts(body).tokens, 0);
  assert.equal(db.table("live_activity_tokens").length, 2, "and both survive");
});

Deno.test("an activity on a phone whose day has moved past this window is skipped", async () => {
  const db = circleWith([
    { user: AMINA, token: "amina-activity", kind: "update" },
    { user: BILAL, token: "bilal-activity", kind: "update", zone: MUMBAI },
  ]);
  const { body, fans } = await run(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  const activity = fans.filter((f) => f.pushType === APNS_LIVE_ACTIVITY_PUSH_TYPE);
  assert.equal(activity.length, 1);
  assert.equal(activity[0].devices, 1, "Bilal's evening is not Yusuf's dawn");
  const counts = liveActivityCounts(body);
  assert.equal(counts.updated, 1);
  assert.equal(counts.outOfZone, 1);
});

Deno.test("`youLogged` is the only per-phone field, so it costs one extra fan-out", async () => {
  // Amina has prayed this window; Hanif has not. One payload each, not one per
  // person — a circle of eight would otherwise be eight 4 KB serialisations for
  // two distinct strings.
  const db = circleWith([
    { user: AMINA, token: "amina-activity", kind: "update" },
    { user: HANIF, token: "hanif-activity", kind: "update" },
  ]);
  db.table("posts").push({
    id: "b1000000-0000-4000-8000-000000000002",
    user_id: AMINA,
    circle_id: CIRCLE,
    day_key: DAY_KEY,
    prayer: "fajr",
    tier: "prayed",
    jamaat: false,
    place_label: null,
    utc_offset: SEATTLE,
    logged_at: "2026-08-22T11:55:00Z",
    notified_at: "2026-08-22T11:55:01Z",
  });
  const { body, fans } = await run(
    FAJR,
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  const activity = fans.filter((f) => f.pushType === APNS_LIVE_ACTIVITY_PUSH_TYPE);
  assert.equal(activity.length, 2, "one payload for prayed, one for not");
  assert.deepEqual(activity.map((f) => f.devices).sort(), [1, 1]);
  const counts = liveActivityCounts(body);
  assert.equal(counts.tokens, 2);
  assert.equal(counts.updated, 2);
});

Deno.test("an activity whose window has closed is ended and its token dropped", async () => {
  // Reachable in ordinary use: a make-up logged after the window closes is
  // still a post for that (day, prayer), and it must not resurrect an activity
  // the app has not been awake to end itself.
  const db = circleWith([
    { user: AMINA, token: "amina-activity", kind: "update" },
  ]);
  const { body, fans } = await run(
    "2026-08-22T14:30:00Z", // an hour and a half after WINDOW_END
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  const activity = fans.filter((f) => f.pushType === APNS_LIVE_ACTIVITY_PUSH_TYPE);
  assert.equal(activity.length, 1);
  const counts = liveActivityCounts(body);
  assert.equal(counts.ended, 1);
  assert.equal(counts.updated, 0);
  assert.equal(
    db.table("live_activity_tokens").length,
    0,
    "a retired activity's address was kept",
  );
});

Deno.test("an activity with no recorded end is moved, never retired", async () => {
  // Unknown never means silence — the same call zones.ts makes about an unknown
  // offset. A row written by a build that did not send `ends_at` still updates;
  // it simply gets no stale date.
  const db = circleWith([
    { user: AMINA, token: "amina-activity", kind: "update", endsAt: null },
  ]);
  const { body } = await run(
    // The same instant the test above retires an activity at — an hour and a
    // half past WINDOW_END, and still the recipient's own day. The ONLY
    // difference between the two is whether the row knows when its window ends.
    "2026-08-22T14:30:00Z",
    () => notifyPost(db.asClient(), CALLER, POST),
  );
  const counts = liveActivityCounts(body);
  assert.equal(counts.updated, 1);
  assert.equal(counts.ended, 0);
  assert.equal(db.table("live_activity_tokens").length, 1);
});

Deno.test("a circle with no activities costs no extra queries", async () => {
  // The fan-out reads the roster, then the tokens, and stops. `postsInWindow`
  // and `profilesFor` are two more round trips inside one invocation's wall
  // clock, and there is nothing to spend them on.
  const db = circleWith([]);
  await run(FAJR, () => notifyPost(db.asClient(), CALLER, POST));
  assert.equal(
    db.queries.filter((q) => q.table === "live_activity_tokens").length,
    1,
    "the token lookup runs exactly once",
  );
  assert.equal(
    db.queries.filter((q) => q.table === "profiles").length,
    0,
    "faces were built for nobody",
  );
  // `isFirstPostInWindow` reads the same three columns of `posts` and is NOT
  // this; it is told apart by the `id=neq` that makes it "is there an EARLIER
  // one". `postsInWindow` asks for the whole window.
  assert.equal(
    db.queries.filter((q) =>
      q.table === "posts" &&
      q.filters.includes("prayer=eq.fajr") &&
      !q.filters.some((f) => f.startsWith("id=neq."))
    ).length,
    0,
    "the window read happened with no activity to send it to",
  );
});
