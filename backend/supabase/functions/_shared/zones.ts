// Is a post's day still TODAY for the person we are about to wake up?
//
// `day_key` is the client's LOCAL schedule day ("yyyy-MM-dd"). It is the same
// string for everybody in the circle, and it means a different stretch of real
// time for each of them. Until now `notify` fanned a post out to every member
// regardless: post Fajr at 5am in Mumbai and your friend in Seattle is buzzed
// at 4:30pm, half a day after their own Fajr, about a window that closed before
// their lunch. That is the noise this module exists to remove.
//
// Everything here is PURE — no clock read, no network, no Deno APIs — so the
// whole rule is exercised offline in tests/deno/zones_test.ts. `nowMs` is
// always a parameter for the same reason `GameEngine` takes its inputs
// explicitly on the Swift side.

/// A device or post row that may or may not know where it is.
export interface ZoneAware {
  utc_offset?: number | null;
}

const DAY_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

const DAY_MS = 86_400_000;

/// How long after local midnight somebody is still living YESTERDAY's schedule
/// day.
///
/// `day_key` names a SCHEDULE day, not a calendar day, and between midnight and
/// dawn the two are different dates: the isha window runs until the next fajr,
/// so at 00:30 the prayer you are in the middle of belongs to yesterday's key.
/// The client draws that line at the real fajr Adhan computed for its
/// coordinates. This module has no coordinates and no schedule, so it
/// approximates with a flat four hours of local time.
///
/// Four, and not two or six, because the two failures are not symmetric. Too
/// generous and a recipient whose fajr has already broken gets a push that is
/// merely stale — the failure this module accepts everywhere else. Too tight
/// and a recipient still in yesterday's isha gets nothing — the failure it
/// refuses. Four clears every ordinary fajr; it over-sends for an hour or so
/// into high-latitude midsummer, where fajr can break before 03:00 or not
/// resolve at all, and still stops well short of the hours where a morning is
/// plainly under way.
export const PRE_DAWN_SECONDS = 4 * 3600;

/// The widest offset a live device can honestly report: UTC-12:00 to UTC+14:00,
/// rounded out to a flat ±14h. Matches `devices_utc_offset_range` in
/// 20260822000500 — anything outside it is a broken clock, not a place, and is
/// read here as "unknown" rather than acted on.
export const MAX_UTC_OFFSET_SECONDS = 14 * 3600;

/// How far past the poster's own local clock reading a recipient may be before
/// "X posted first for Fajr" stops being news for them.
///
/// The date check alone is not enough, and the case it misses is the one this
/// whole filter was written for. A Seattle member logs Fajr at 05:00 PDT; a
/// Mumbai circle-mate is at 17:30 on the SAME calendar date, so a date-only
/// rule keeps them and buzzes them about a window that closed twelve and a half
/// hours earlier. Only the westbound direction was ever caught.
///
/// Comparing local CLOCK READINGS works because a prayer time is a solar event:
/// dawn is dawn at roughly the same local hour wherever you stand, so "what
/// does their clock say versus what did the poster's clock say" is a decent
/// proxy for "is their window near" without Adhan on the server.
///
/// Four hours, and the asymmetry below matters more than the number: a
/// recipient BEHIND the poster is never dropped, because someone whose window
/// has not opened yet is exactly who a "posted first" push is meant to move.
export const STALE_AFTER_SECONDS = 4 * 3600;

/// True for a value that names a real place on the earth.
///
/// Deliberately NOT true for `null`/`undefined`: a missing offset is a distinct
/// third answer, and the whole point of this module is that it never collapses
/// into a zone. Note that `0` is a real offset (London in winter), which is why
/// nothing here tests an offset for truthiness.
export function isKnownOffset(
  offset: number | null | undefined,
): offset is number {
  return typeof offset === "number" && Number.isFinite(offset) &&
    Math.abs(offset) <= MAX_UTC_OFFSET_SECONDS;
}

/// The local calendar day at `nowMs` for somebody `utcOffsetSeconds` from UTC,
/// or null when we do not know where they are.
///
/// Half-hour and quarter-hour zones (India +5:30, Nepal +5:45, Chatham +12:45)
/// fall out for free: the offset is in SECONDS and is simply added to the
/// instant before the UTC date is read off it.
export function localDayKey(
  nowMs: number,
  utcOffsetSeconds: number | null | undefined,
): string | null {
  if (!Number.isFinite(nowMs)) return null;
  if (!isKnownOffset(utcOffsetSeconds)) return null;
  const shifted = new Date(nowMs + utcOffsetSeconds * 1000);
  let iso: string;
  try {
    iso = shifted.toISOString();
  } catch {
    // `nowMs` outside the representable range. Not reachable from Date.now(),
    // but this is the one place a throw would take a whole fan-out down.
    return null;
  }
  const day = iso.slice(0, 10);
  // Years outside 1000-9999 render as "+033658-09-27T…", which would compare
  // as a string against real day keys and lose. Refuse rather than mis-order.
  return DAY_KEY_RE.test(day) ? day : null;
}

/// Seconds elapsed since local midnight for somebody `utcOffsetSeconds` from
/// UTC — in `[0, 86400)` — or null when we do not know where they are.
export function localSecondsIntoDay(
  nowMs: number,
  utcOffsetSeconds: number | null | undefined,
): number | null {
  if (!Number.isFinite(nowMs)) return null;
  if (!isKnownOffset(utcOffsetSeconds)) return null;
  const shifted = nowMs + utcOffsetSeconds * 1000;
  // Floored modulo, not a bare `%`: JS keeps the sign of the dividend, so an
  // instant before the epoch (or a westward offset that pushes one there) would
  // report a NEGATIVE time of day and read as pre-dawn everywhere.
  const intoDay = ((shifted % DAY_MS) + DAY_MS) % DAY_MS;
  return Math.floor(intoDay / 1000);
}

/// Is it still before dawn where this recipient is standing?
///
/// False when we do not know where they are: "unknown" is answered once, in
/// `isCurrentForOffset`, by keeping the device — never by guessing a zone here.
export function isPreDawn(
  nowMs: number,
  utcOffsetSeconds: number | null | undefined,
): boolean {
  const intoDay = localSecondsIntoDay(nowMs, utcOffsetSeconds);
  return intoDay !== null && intoDay < PRE_DAWN_SECONDS;
}

/// Parses a "yyyy-MM-dd" schedule day to the UTC midnight that represents it,
/// or null if it is not one. Only ever used to ORDER two day keys against each
/// other, never as a real instant.
export function dayKeyMs(dayKey: string): number | null {
  if (typeof dayKey !== "string" || !DAY_KEY_RE.test(dayKey)) return null;
  const ms = Date.parse(`${dayKey}T00:00:00Z`);
  if (Number.isNaN(ms)) return null;
  // V8 ROLLS OVER rather than rejecting: Date.parse("2026-02-30T00:00:00Z") is
  // March 2nd, not NaN. Round-tripping is the only way to tell a real calendar
  // day from one that merely looks like one — the same check `isDayKey` makes
  // in validate.ts, and the reason this is not a bare parse.
  return new Date(ms).toISOString().slice(0, 10) === dayKey ? ms : null;
}

/// The calendar day before `dayKey`, or null if that is not a real day key.
/// Month ends, year ends and leap days are the calendar's problem, not a string
/// decrement's.
function previousDayKey(dayKey: string): string | null {
  const ms = dayKeyMs(dayKey);
  if (ms === null) return null;
  const day = new Date(ms - DAY_MS).toISOString().slice(0, 10);
  return DAY_KEY_RE.test(day) ? day : null;
}

/// The span of local days for which a post is still current news.
///
/// `from`/`to` are inclusive "yyyy-MM-dd" bounds.
export interface DayWindow {
  from: string;
  to: string;
  /// The poster's own local time-of-day, in seconds since their local midnight,
  /// AT THE MOMENT THEY LOGGED. Null when it cannot be derived, which is read
  /// as "do not apply the time-of-day check" — the same do-not-filter posture
  /// the rest of this file takes toward anything unknown.
  posterLocalSeconds?: number | null;
}

/// The days on which this post is still "today", as seen from anywhere.
///
/// It is the range between the post's `day_key` and the POSTER'S OWN current
/// local day — normally the same date, so the range is a single day. The two
/// differ in exactly one ordinary case, and it is a case that must not be
/// filtered: an Isha logged after midnight carries YESTERDAY's `day_key` (its
/// window ends at today's Fajr), so the poster's own clock already reads
/// `day_key + 1`. Anchoring on the poster gives the invariant that matters —
///
///     nobody standing in the poster's own zone is ever filtered out
///
/// — for free, and it holds for a backdated make-up post too. It is only half
/// the allowance, though: the same after-midnight rule has to be applied to the
/// RECIPIENT before the window is judged, and `isCurrentForOffset` is where
/// that happens.
///
/// Returns null for "do not filter at all", which is the honest answer when the
/// poster's own zone is unknown (a row written before 20260822000200, or by a
/// build that predates it): with no idea where the post came from, a recipient
/// on a different date could be half a world away or could be the same city
/// four minutes after midnight, and there is no way to tell them apart.
export function relevanceWindow(
  dayKey: string,
  posterUtcOffset: number | null | undefined,
  nowMs: number,
  loggedAtMs?: number | null,
): DayWindow | null {
  // Not a real calendar day (a hand-rolled caller, a column CHECK that grew a
  // hole): nothing to anchor on, so nothing is filtered.
  if (dayKeyMs(dayKey) === null) return null;
  const posterDay = localDayKey(nowMs, posterUtcOffset);
  if (posterDay === null) return null;
  // Optional so a caller that has no logged_at (or a test constructing a window
  // by hand) degrades to the date-only behaviour rather than breaking.
  const posterLocalSeconds = typeof loggedAtMs === "number"
    ? localSecondsIntoDay(loggedAtMs, posterUtcOffset)
    : null;
  return posterDay < dayKey
    ? { from: posterDay, to: dayKey, posterLocalSeconds }
    : { from: dayKey, to: posterDay, posterLocalSeconds };
}

/// Is the post still today for a recipient at this offset?
///
/// A NULL/unknown offset is ALWAYS true. Unknown must never mean silence: every
/// device registered before 20260822000500 has no offset, and treating those as
/// UTC+0 would mute a real person on the strength of a value nobody ever wrote.
/// The failure we accept is a push that is stale; the failure we refuse is a
/// push that never arrives.
///
/// The question is asked of the recipient's SCHEDULE day, and before dawn that
/// is not their calendar day. `relevanceWindow` already makes exactly this
/// allowance on the POSTER'S side — a two-date window is what an isha logged at
/// 00:30 produces — and the recipient needs the mirror image of it, or the same
/// midnight cuts differently depending on whose zone it falls in. The pair that
/// proves it: poster in London at 23:30, so the window is a single day; a
/// circle-mate one hour east reads 00:30, the SAME clock face that keeps a
/// same-city recipient in, and was dropped for standing on tomorrow's date.
/// Seattle/Denver and UK/Central Europe lose the "posted first for isha" push
/// that way most nights of the year.
///
/// So before dawn BOTH candidates are accepted: yesterday's isha is still open
/// and today's fajr is about to be, and which of the two a bare `day_key`
/// belongs to is not knowable from here. That widens the top of the window by
/// exactly one day, which can only ever ADD recipients — the invariant that
/// nobody in the poster's own zone is ever filtered is untouched, and no push
/// this rule already delivered goes away. What it does admit is a recipient
/// many zones east of the poster hearing at 02:00 about a window that closed
/// for them in daylight; that is the same over-send the poster anchor makes,
/// and the same trade: stale beats silent.
export function isCurrentForOffset(
  window: DayWindow | null,
  recipientUtcOffset: number | null | undefined,
  nowMs: number,
): boolean {
  if (window === null) return true;
  const day = localDayKey(nowMs, recipientUtcOffset);
  if (day === null) return true;
  // Lexicographic ordering is date ordering for zero-padded yyyy-MM-dd.
  if (day >= window.from && day <= window.to) {
    return !isStaleForTimeOfDay(window, recipientUtcOffset, nowMs);
  }
  // One date past the top of the window, before dawn: the calendar has turned
  // over for them but the schedule day has not.
  return isPreDawn(nowMs, recipientUtcOffset) &&
    previousDayKey(day) === window.to;
}

/// Within a date the window already accepts, has the recipient's own clock run
/// too far past the poster's to make this news?
///
/// Deliberately one-directional. `ahead > 0` means their clock has passed the
/// reading the poster logged at, so their equivalent window is behind them;
/// `ahead <= 0` means it is still coming and they are precisely the person the
/// push is for. Only the first case can ever drop anybody.
///
/// Every unknown answers false — keep the device. That is the same trade the
/// rest of this file makes: the failure we accept is a push that is stale, the
/// failure we refuse is a push that never arrives.
export function isStaleForTimeOfDay(
  window: DayWindow,
  recipientUtcOffset: number | null | undefined,
  nowMs: number,
): boolean {
  const posterLocal = window.posterLocalSeconds;
  if (typeof posterLocal !== "number") return false;
  const recipientLocal = localSecondsIntoDay(nowMs, recipientUtcOffset);
  if (recipientLocal === null) return false;
  // No circular distance here, on purpose: 21 hours ahead and 3 hours behind
  // are the same angle on a clock face, and collapsing them would drop the
  // westward recipient whose window has not opened yet. Both readings sit on
  // the same schedule day by the time this runs, so a plain subtraction says
  // what a modulo cannot.
  const ahead = recipientLocal - posterLocal;
  return ahead > STALE_AFTER_SECONDS;
}

/// Splits a fan-out list into the devices this post is still news for, and the
/// ones whose day has moved on.
///
/// Per DEVICE, not per user, on purpose: the phone in a traveller's pocket
/// re-registers with its new offset on the next foreground, while the iPad left
/// at home still says the old one. Each row is judged where it actually is.
export function partitionByRelevance<T extends ZoneAware>(
  devices: readonly T[],
  window: DayWindow | null,
  nowMs: number,
): { current: T[]; stale: T[] } {
  if (window === null) return { current: [...devices], stale: [] };
  const current: T[] = [];
  const stale: T[] = [];
  for (const device of devices) {
    if (isCurrentForOffset(window, device.utc_offset, nowMs)) {
      current.push(device);
    } else stale.push(device);
  }
  return { current, stale };
}
