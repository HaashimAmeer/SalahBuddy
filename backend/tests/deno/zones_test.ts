// Whether a circle push is still about TODAY for the person receiving it.
//
// `day_key` is one string that means a different stretch of real time for every
// member of a cross-timezone circle, and `notify` used to fan a post out to all
// of them regardless. These tests are written as real journeys — a 5am Fajr in
// Mumbai, a 10pm Isha in Seattle, an Isha logged at half past midnight — rather
// than as arithmetic, because the whole class of bug here is being confidently
// wrong about which day somebody is standing in.

import assert from "node:assert/strict";
import {
  isCurrentForOffset,
  isKnownOffset,
  isPreDawn,
  isStaleForTimeOfDay,
  STALE_AFTER_SECONDS,
  localDayKey,
  localSecondsIntoDay,
  MAX_UTC_OFFSET_SECONDS,
  partitionByRelevance,
  PRE_DAWN_SECONDS,
  relevanceWindow,
} from "../../supabase/functions/_shared/zones.ts";

// Real places, in the unit the column stores (seconds east of UTC).
const SEATTLE = -7 * 3600; // PDT
const DENVER = -6 * 3600; // MDT, one hour east of Seattle
const MUMBAI = 5 * 3600 + 30 * 60; // IST, a half-hour zone
const KATHMANDU = 5 * 3600 + 45 * 60; // NPT, a quarter-hour zone
const DHAKA = 6 * 3600; // BST, fifteen minutes east of Kathmandu
const LONDON_WINTER = 0; // a REAL offset, not "unknown"
const LONDON_SUMMER = 3600; // the same city in August
const BERLIN_WINTER = 3600;
const AUCKLAND = 12 * 3600;

/// A `devices` row, trimmed to the one column this module reads.
function device(token: string, utc_offset: number | null) {
  return { apns_token: token, utc_offset };
}

function at(iso: string): number {
  const ms = Date.parse(iso);
  assert.ok(!Number.isNaN(ms), `bad instant in test: ${iso}`);
  return ms;
}

// --------------------------------------------------------------- local day

Deno.test("localDayKey reads the calendar day the offset is standing in", () => {
  // 2026-08-21 23:30 UTC. Mumbai has already ticked over; Seattle has not.
  const now = at("2026-08-21T23:30:00Z");
  assert.equal(localDayKey(now, MUMBAI), "2026-08-22");
  assert.equal(localDayKey(now, SEATTLE), "2026-08-21");
  assert.equal(localDayKey(now, LONDON_WINTER), "2026-08-21");
});

Deno.test("localDayKey handles the half- and quarter-hour zones", () => {
  // 18:20 UTC: +5:30 is still on the 21st (23:50), +5:45 has crossed (00:05).
  // Fifteen minutes of offset decide the date, so the arithmetic has to be in
  // seconds and not in whole hours.
  const now = at("2026-08-21T18:20:00Z");
  assert.equal(localDayKey(now, MUMBAI), "2026-08-21");
  assert.equal(localDayKey(now, KATHMANDU), "2026-08-22");
  assert.equal(localDayKey(now, 12 * 3600 + 45 * 60), "2026-08-22", "Chatham");
});

Deno.test("an unknown offset is not a zone", () => {
  const now = at("2026-08-21T23:30:00Z");
  assert.equal(localDayKey(now, null), null);
  assert.equal(localDayKey(now, undefined), null);
  assert.equal(localDayKey(now, Number.NaN), null);
  // Out of the range a live device can honestly report: a broken clock, read
  // as "we do not know" rather than acted on.
  assert.equal(localDayKey(now, MAX_UTC_OFFSET_SECONDS + 1), null);
  assert.equal(localDayKey(now, -MAX_UTC_OFFSET_SECONDS - 1), null);
});

Deno.test("localSecondsIntoDay reads the local clock face, quarter-hours included", () => {
  const now = at("2026-08-21T18:20:00Z");
  assert.equal(localSecondsIntoDay(now, LONDON_WINTER), 18 * 3600 + 20 * 60);
  assert.equal(localSecondsIntoDay(now, SEATTLE), 11 * 3600 + 20 * 60);
  assert.equal(localSecondsIntoDay(now, KATHMANDU), 5 * 60, "00:05");
  assert.equal(localSecondsIntoDay(now, null), null);
  assert.equal(localSecondsIntoDay(now, 999_999), null);
  // Before the epoch, where a bare `%` keeps the dividend's sign and would
  // report a negative time of day — i.e. pre-dawn, everywhere, forever.
  const beforeEpoch = at("1969-12-31T23:00:00Z");
  assert.equal(localSecondsIntoDay(beforeEpoch, LONDON_WINTER), 23 * 3600);
  assert.equal(isPreDawn(beforeEpoch, LONDON_WINTER), false);
  assert.equal(isPreDawn(beforeEpoch, 2 * 3600), true, "01:00 on the 1st");
});

Deno.test("isPreDawn does not guess at a zone it was not given", () => {
  const midnightUTC = at("2026-08-22T00:30:00Z");
  assert.equal(isPreDawn(midnightUTC, LONDON_WINTER), true);
  // Unknown is answered once, by keeping the device in isCurrentForOffset —
  // never by defaulting to a zone here.
  assert.equal(isPreDawn(midnightUTC, null), false);
  assert.equal(isPreDawn(midnightUTC, undefined), false);
  assert.equal(isPreDawn(midnightUTC, Number.NaN), false);
});

Deno.test("zero is a real place, and is never confused with unknown", () => {
  // London in winter, Reykjavík all year, Accra. The bug a `not null default 0`
  // column would have shipped: everybody unknown filed under Greenwich.
  assert.equal(isKnownOffset(LONDON_WINTER), true);
  assert.equal(isKnownOffset(null), false);
  assert.equal(isKnownOffset(undefined), false);
  assert.equal(isKnownOffset(MAX_UTC_OFFSET_SECONDS), true);
  assert.equal(isKnownOffset(MAX_UTC_OFFSET_SECONDS + 1), false);
});

// ------------------------------------------------------- the fan-out filter

Deno.test("same zone: the circle-mate next door is always notified", () => {
  // Seattle, Isha at 22:00 on the 21st. Everybody else in Seattle is on the
  // same date, at the same moment, and must hear about it.
  const now = at("2026-08-22T05:00:00Z");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  assert.deepEqual(window, { from: "2026-08-21", to: "2026-08-21", posterLocalSeconds: null });
  assert.equal(isCurrentForOffset(window, SEATTLE, now), true);
});

Deno.test("a recipient half a day ahead is skipped: it is already yesterday for them", () => {
  // The 10pm Isha above, arriving in Mumbai. It is 10:30 the NEXT MORNING
  // there — the poster's day_key is yesterday's date, about a window that
  // closed while the recipient was asleep.
  const now = at("2026-08-22T05:00:00Z");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  assert.equal(localDayKey(now, MUMBAI), "2026-08-22");
  assert.equal(isCurrentForOffset(window, MUMBAI, now), false);
});

Deno.test("the 5am Mumbai Fajr does not buzz Seattle at half past four", () => {
  // THE bug this module exists for (SPEC-V4 §6). 05:00 IST on the 22nd is
  // 16:30 PDT on the 21st: twelve hours after the Seattle member's own Fajr,
  // and a calendar day short of the poster's day_key.
  const now = at("2026-08-21T23:30:00Z");
  const window = relevanceWindow("2026-08-22", MUMBAI, now);
  assert.deepEqual(window, { from: "2026-08-22", to: "2026-08-22", posterLocalSeconds: null });
  assert.equal(localDayKey(now, SEATTLE), "2026-08-21");
  assert.equal(isCurrentForOffset(window, SEATTLE, now), false);
  // ...while everyone actually in the poster's morning still hears it, half-
  // hour and quarter-hour zones included.
  assert.equal(isCurrentForOffset(window, MUMBAI, now), true);
  assert.equal(isCurrentForOffset(window, KATHMANDU, now), true);
});

Deno.test("a NULL offset is always notified — unknown never means silence", () => {
  // Every `devices` row written before 20260822000500 has no offset. Treating
  // those as UTC+0 would mute a real person on the strength of a value nobody
  // ever wrote, so they are kept whatever the window says.
  const now = at("2026-08-22T05:00:00Z");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  assert.equal(isCurrentForOffset(window, null, now), true);
  assert.equal(isCurrentForOffset(window, undefined, now), true);
  // A nonsense offset degrades the same way, rather than muting the device.
  assert.equal(isCurrentForOffset(window, 999_999, now), true);
});

Deno.test("an Isha logged after midnight still reaches the same city", () => {
  // 00:30 on the 22nd in Seattle. The Isha window ends at the 22nd's Fajr, so
  // the post carries the 21st's day_key while the poster's own clock already
  // reads the 22nd — and so does every circle-mate in town. Anchoring the
  // window on the POSTER is what keeps them in it.
  const now = at("2026-08-22T07:30:00Z");
  assert.equal(localDayKey(now, SEATTLE), "2026-08-22");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  assert.deepEqual(window, { from: "2026-08-21", to: "2026-08-22", posterLocalSeconds: null });
  assert.equal(isCurrentForOffset(window, SEATTLE, now), true);
});

Deno.test("nobody standing in the poster's own zone is ever filtered", () => {
  // The invariant the window is built to guarantee, checked across a whole day
  // of instants and a spread of zones — including a backdated make-up post,
  // where day_key and the poster's own day are five days apart.
  for (const offset of [SEATTLE, MUMBAI, KATHMANDU, LONDON_WINTER, AUCKLAND]) {
    for (let hour = 0; hour < 24; hour++) {
      const now = at(`2026-08-21T${String(hour).padStart(2, "0")}:07:00Z`);
      const today = localDayKey(now, offset);
      assert.ok(today !== null);
      for (const dayKey of [today, "2026-08-16"]) {
        const window = relevanceWindow(dayKey, offset, now);
        assert.equal(
          isCurrentForOffset(window, offset, now),
          true,
          `offset ${offset} at ${hour}:07Z filtered itself out for ${dayKey}`,
        );
      }
    }
  }
});

Deno.test("a fifteen-minute offset can be the whole difference", () => {
  // 23:10 BST in London. Kathmandu reads 03:55 and is still inside its isha;
  // Dhaka is fifteen minutes further east at 04:10 with fajr imminent, so the
  // same alert is current in Nepal and stale in Bangladesh. Whole-hour
  // arithmetic could not tell the two apart.
  const now = at("2026-08-21T22:10:00Z");
  const window = relevanceWindow("2026-08-21", LONDON_SUMMER, now);
  assert.deepEqual(window, { from: "2026-08-21", to: "2026-08-21", posterLocalSeconds: null });
  assert.equal(isCurrentForOffset(window, KATHMANDU, now), true);
  assert.equal(isCurrentForOffset(window, DHAKA, now), false);
});

Deno.test("zero is compared like any other offset, not treated as a fallback", () => {
  // London logs isha at 23:30 GMT. Mumbai is 05:00 the next morning, past its
  // own fajr, and is dropped — which can only happen if offset 0 was read as a
  // real place. Had it been shrugged off as "unknown" the window would be null
  // and nobody would be filtered at all.
  const now = at("2026-01-15T23:30:00Z");
  const window = relevanceWindow("2026-01-15", LONDON_WINTER, now);
  assert.deepEqual(window, { from: "2026-01-15", to: "2026-01-15", posterLocalSeconds: null });
  assert.equal(isCurrentForOffset(window, LONDON_WINTER, now), true);
  assert.equal(localDayKey(now, MUMBAI), "2026-01-16");
  assert.equal(isPreDawn(now, MUMBAI), false);
  assert.equal(isCurrentForOffset(window, MUMBAI, now), false);
});

// ------------------------------------------- the recipient's after-midnight

Deno.test("the circle-mate one zone east is at 00:30, not on another day", () => {
  // THE asymmetry. relevanceWindow corrects for the house rule that an isha
  // logged after midnight carries YESTERDAY's day_key — but that correction was
  // only ever applied to the POSTER. London logs isha at 23:30, so the window
  // is a single date; Berlin reads 00:30, which is the SAME clock face that
  // keeps a same-city recipient in ("an Isha logged after midnight still
  // reaches the same city" above), and used to be dropped purely for standing
  // on tomorrow's date. Their isha runs until their fajr, so by the app's own
  // dayKey rule the post is about the schedule day they are standing in.
  const now = at("2026-01-15T23:30:00Z");
  const window = relevanceWindow("2026-01-15", LONDON_WINTER, now);
  assert.deepEqual(window, { from: "2026-01-15", to: "2026-01-15", posterLocalSeconds: null });
  assert.equal(localDayKey(now, BERLIN_WINTER), "2026-01-16");
  assert.equal(isPreDawn(now, BERLIN_WINTER), true);
  assert.equal(isCurrentForOffset(window, BERLIN_WINTER, now), true);
  // Same instant, same open isha, same answer as the poster's own zone.
  assert.equal(isCurrentForOffset(window, LONDON_WINTER, now), true);
});

Deno.test("Seattle's summer isha still reaches Denver a quarter hour into tomorrow", () => {
  // The shape that hit a real circle nightly: 23:15 PDT in August is 00:15 MDT.
  // Denver is inside its own isha; Mumbai, at 11:45 the next morning, is not.
  const now = at("2026-08-22T06:15:00Z");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  assert.deepEqual(window, { from: "2026-08-21", to: "2026-08-21", posterLocalSeconds: null });
  assert.equal(localDayKey(now, DENVER), "2026-08-22");
  assert.equal(isCurrentForOffset(window, DENVER, now), true);
  assert.equal(localDayKey(now, MUMBAI), "2026-08-22");
  assert.equal(isCurrentForOffset(window, MUMBAI, now), false);
});

Deno.test("the allowance ends at dawn, not at the end of the day", () => {
  // The same Seattle isha read in London: 07:15 the next morning, hours after
  // their own fajr. Being one date past the window is not a free pass — being
  // before dawn on that date is.
  const now = at("2026-08-22T06:15:00Z");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  assert.equal(localDayKey(now, LONDON_SUMMER), "2026-08-22");
  assert.equal(isPreDawn(now, LONDON_SUMMER), false);
  assert.equal(isCurrentForOffset(window, LONDON_SUMMER, now), false);
});

Deno.test("the allowance is exactly one day wide and expires on the second", () => {
  // Pins the constant, and crosses a month end on purpose: "the day before
  // 2026-04-01" is a calendar question, not a string decrement.
  const window = { from: "2026-03-31", to: "2026-03-31" };
  const midnight = at("2026-04-01T00:00:00Z");
  const lastSecond = midnight + PRE_DAWN_SECONDS * 1000 - 1000;
  assert.equal(localDayKey(lastSecond, LONDON_WINTER), "2026-04-01");
  assert.equal(isCurrentForOffset(window, LONDON_WINTER, lastSecond), true);
  const dawn = midnight + PRE_DAWN_SECONDS * 1000;
  assert.equal(isCurrentForOffset(window, LONDON_WINTER, dawn), false);
  // Two dates past is never current, however early in the night it is.
  const nextNight = at("2026-04-02T00:30:00Z");
  assert.equal(isPreDawn(nextNight, LONDON_WINTER), true);
  assert.equal(isCurrentForOffset(window, LONDON_WINTER, nextNight), false);
});

Deno.test("an hour east of a late isha is kept wherever on earth the pair stands", () => {
  // Generalises the London/Berlin pair: it was never about Greenwich. For a
  // poster who logs isha at 23:30 ANYWHERE, the circle-mate an hour east reads
  // 00:30 and has to hear about it.
  for (let poster = -11 * 3600; poster <= 12 * 3600; poster += 3600) {
    const now = at("2026-01-15T23:30:00Z") - poster * 1000; // 23:30 local
    assert.equal(localDayKey(now, poster), "2026-01-15");
    const window = relevanceWindow("2026-01-15", poster, now);
    assert.equal(
      isCurrentForOffset(window, poster + 3600, now),
      true,
      `poster at ${poster} dropped the neighbour an hour east`,
    );
  }
});

// ------------------------------------------------------------ "do not filter"

Deno.test("a post with no zone of its own filters nobody", () => {
  // Written by a build older than 20260822000200. With no idea where the post
  // came from, a recipient on a different date could be half a world away or
  // could be the same city four minutes after midnight — and there is no way
  // to tell those apart, so nothing is dropped.
  const now = at("2026-08-22T05:00:00Z");
  assert.equal(relevanceWindow("2026-08-21", null, now), null);
  assert.equal(relevanceWindow("2026-08-21", undefined, now), null);
  assert.equal(isCurrentForOffset(null, MUMBAI, now), true);
});

Deno.test("a malformed day_key filters nobody", () => {
  const now = at("2026-08-22T05:00:00Z");
  assert.equal(relevanceWindow("2026-02-30", SEATTLE, now), null);
  assert.equal(relevanceWindow("21-08-2026", SEATTLE, now), null);
  assert.equal(relevanceWindow("", SEATTLE, now), null);
});

// ------------------------------------------------------------- the partition

Deno.test("partitionByRelevance splits per DEVICE, not per user", () => {
  // The traveller's phone re-registers with its new offset on the next
  // foreground; the iPad left at home still says the old one. Each row is
  // judged where it actually is.
  const now = at("2026-08-22T05:00:00Z");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  const { current, stale } = partitionByRelevance(
    [
      device("home-mac", SEATTLE),
      device("travelling-phone", MUMBAI),
      device("legacy-ipad", null),
    ],
    window,
    now,
  );
  assert.deepEqual(current.map((d) => d.apns_token), [
    "home-mac",
    "legacy-ipad",
  ]);
  assert.deepEqual(stale.map((d) => d.apns_token), ["travelling-phone"]);
});

Deno.test("partitionByRelevance keeps the phone that is just past midnight", () => {
  // The fan-out end of the Seattle/Denver case: the eastern phone belongs in
  // `current`, not counted as out-of-zone and silently dropped.
  const now = at("2026-08-22T06:15:00Z");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  const { current, stale } = partitionByRelevance(
    [
      device("seattle-phone", SEATTLE),
      device("denver-phone", DENVER),
      device("mumbai-phone", MUMBAI),
    ],
    window,
    now,
  );
  assert.deepEqual(current.map((d) => d.apns_token), [
    "seattle-phone",
    "denver-phone",
  ]);
  assert.deepEqual(stale.map((d) => d.apns_token), ["mumbai-phone"]);
});

Deno.test("a null window is the join and nudge path: everyone is kept", () => {
  // `fanOut` passes `relevance` only for POSTS. "Yusuf joined your circle" is
  // not about a day, and a nudge never reaches this code at all — it is aimed
  // at one named person who was just picked out of a grid.
  const now = at("2026-08-22T05:00:00Z");
  const devices = [
    device("seattle", SEATTLE),
    device("mumbai", MUMBAI),
    device("unknown", null),
  ];
  const { current, stale } = partitionByRelevance(devices, null, now);
  assert.equal(current.length, 3);
  assert.equal(stale.length, 0);
});

Deno.test("an empty fan-out is not an error", () => {
  const now = at("2026-08-22T05:00:00Z");
  const window = relevanceWindow("2026-08-21", SEATTLE, now);
  const { current, stale } = partitionByRelevance([], window, now);
  assert.deepEqual(current, []);
  assert.deepEqual(stale, []);
});

// ---------------------------------------------------------------------------
// Time of day, not just the date.
//
// The date check alone let through the exact case the whole filter exists for:
// a Seattle Fajr at 05:00 and a Mumbai member at 17:30 share a calendar date,
// so a date-only rule buzzed them about a window that closed twelve and a half
// hours earlier. Only the westbound direction was ever caught.

const FAJR_0500_PDT = Date.parse("2026-08-22T12:00:00Z"); // 05:00 in Seattle

function seattleFajrWindow() {
  return relevanceWindow("2026-08-22", SEATTLE, FAJR_0500_PDT, FAJR_0500_PDT);
}

Deno.test("the window carries the poster's own clock reading", () => {
  const w = seattleFajrWindow();
  assert.equal(w?.posterLocalSeconds, 5 * 3600);
});

Deno.test("a member half a world east is NOT buzzed about a Fajr their evening has passed", () => {
  // Mumbai, +5:30, reading 17:30 on the same calendar date. This is the bug.
  assert.equal(isCurrentForOffset(seattleFajrWindow(), 5 * 3600 + 1800, FAJR_0500_PDT), false);
  // London, +1, reading 13:00. Also long past.
  assert.equal(isCurrentForOffset(seattleFajrWindow(), 3600, FAJR_0500_PDT), false);
});

Deno.test("a member whose own window has not arrived yet is ALWAYS kept", () => {
  // Hawaii, -10, reading 02:00 — three hours BEHIND the poster. Their Fajr is
  // still coming, which makes them precisely who a "posted first" push is for.
  // A circular distance would have read this as 21 hours ahead and dropped it.
  assert.equal(isCurrentForOffset(seattleFajrWindow(), -10 * 3600, FAJR_0500_PDT), true);
});

Deno.test("neighbours within the tolerance are untouched", () => {
  for (const offset of [SEATTLE, -6 * 3600, -5 * 3600, -4 * 3600]) {
    assert.equal(isCurrentForOffset(seattleFajrWindow(), offset, FAJR_0500_PDT), true);
  }
});

Deno.test("the boundary is exclusive: exactly the tolerance is still news", () => {
  const w = seattleFajrWindow();
  const exactly = SEATTLE + STALE_AFTER_SECONDS;
  assert.equal(isStaleForTimeOfDay(w!, exactly, FAJR_0500_PDT), false);
  assert.equal(isStaleForTimeOfDay(w!, exactly + 1, FAJR_0500_PDT), true);
});

Deno.test("every unknown keeps the device — stale beats silent", () => {
  const w = seattleFajrWindow();
  // Unknown recipient zone.
  assert.equal(isStaleForTimeOfDay(w!, null, FAJR_0500_PDT), false);
  assert.equal(isStaleForTimeOfDay(w!, undefined, FAJR_0500_PDT), false);
  // Unknown poster clock: a window built without logged_at degrades to the
  // date-only behaviour rather than filtering on a value it does not have.
  const dateOnly = relevanceWindow("2026-08-22", SEATTLE, FAJR_0500_PDT);
  assert.equal(dateOnly?.posterLocalSeconds, null);
  assert.equal(isCurrentForOffset(dateOnly, 5 * 3600 + 1800, FAJR_0500_PDT), true);
  // An unparseable logged_at (NaN) is the same kind of unknown.
  const nanLogged = relevanceWindow("2026-08-22", SEATTLE, FAJR_0500_PDT, Number.NaN);
  assert.equal(nanLogged?.posterLocalSeconds, null);
});

Deno.test("a poster with no zone still filters nobody, clock reading or not", () => {
  // relevanceWindow returns null for an unknown poster zone, and null means
  // "do not filter at all" — the time-of-day check must not resurrect filtering.
  const w = relevanceWindow("2026-08-22", null, FAJR_0500_PDT, FAJR_0500_PDT);
  assert.equal(w, null);
  assert.equal(isCurrentForOffset(w, 5 * 3600 + 1800, FAJR_0500_PDT), true);
});
