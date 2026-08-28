// Deciding which `auth.users` rows are safe to delete — the pure half of the
// `sweep-orphans` function.
//
// `delete_account()` erases every row a user owns but cannot touch their
// `auth.users` row: that needs the service-role admin API, and the app signs out
// the moment the RPC returns. The shells pile up — every real deletion, plus the
// three throwaway users the staging smoke job mints on every push.
//
// WHY THIS CANNOT DELETE A REAL ACCOUNT
//
// Every rule below is a reason to KEEP a row, and they are ANDed: a row is
// deleted only when it survives all of them. Adding a rule can therefore only
// ever SHRINK the delete set — there is no combination of these that widens it.
// The first one is the load-bearing one and the rest are belt:
//
//   1. No `public.profiles` row. `on_auth_user_created`
//      (20260821000300_triggers.sql) is an AFTER INSERT trigger on `auth.users`
//      that writes a profile for every account ever created, so a live account
//      HAS one. `authenticated` holds no DELETE grant on `profiles`
//      (20260821000200_rls.sql grants SELECT plus column-scoped INSERT/UPDATE
//      and nothing else — SQL test 12 pins that matrix in both directions), so
//      no client can drop its own profile and keep its account. The only
//      statement in the system that deletes one is `delete_account()`, the RPC
//      behind the app's "Delete account" button. No profile means the human
//      asked us to erase them.
//   2-4. No `circle_members`, `posts` or `devices` row either. Three more of the
//      tables `delete_account()` empties; any one of them still holding a row is
//      proof this is not a finished deletion, whatever the profile says.
//   5. The account is older than `minAgeDays` (30 by default, and never less
//      than SWEEP_MIN_AGE_FLOOR_DAYS however the body is fat-fingered).
//   6. It has not signed in, and has not been touched at all, inside that same
//      window.
//
// A timestamp we cannot read is a KEEP, never a sweep: "I do not know how old
// this row is" must never resolve to "delete it". A brand-new signup that has
// not finished onboarding is protected twice over — it has a profile from the
// trigger, and it is too young.
//
// What is deliberately NOT a criterion: the email address. "Delete everything
// matching salahbuddy-ci-*" is the obvious shortcut and it is the one rule here
// that could take a real person with it — one typo in the pattern, or one human
// who happens to sign up with a similar address, and the sweep is deleting
// accounts nobody deleted. The rules above reach the CI users anyway (they call
// `delete_account()` on their way out, so they clear 1-4 immediately and 5-6
// thirty days later) and they reach genuinely deleted accounts too, which a
// pattern never would.
//
// Deleting the shell is also what finally anonymises anything they reported:
// `reports.reporter_id` is ON DELETE SET NULL precisely so the complaint
// survives the reporter (see backend/README.md, "Reporting a photo").

import { HttpError } from "./http.ts";

/// Tables `delete_account()` empties, in the order the sweep asks about them —
/// `profiles` first because it is the one every live account is guaranteed to
/// have, so it accounts for almost every kept row in a single query.
export const OWNED_TABLES = [
  "profiles",
  "circle_members",
  "posts",
  "devices",
] as const;
export type OwnedTable = typeof OWNED_TABLES[number];

/// The column on each table that carries the account id.
export const OWNED_TABLE_COLUMN: Record<OwnedTable, string> = {
  profiles: "id",
  circle_members: "user_id",
  posts: "user_id",
  devices: "user_id",
};

export const SWEEP_DEFAULT_MIN_AGE_DAYS = 30;
/// However the caller asks, an account younger than this is never swept.
export const SWEEP_MIN_AGE_FLOOR_DAYS = 7;
export const SWEEP_MAX_MIN_AGE_DAYS = 3650;
/// Deletions per run. A criteria bug is then a bounded incident that shows up in
/// the next day's report, not the user table in one tick.
export const SWEEP_DEFAULT_MAX_DELETES = 100;
export const SWEEP_MAX_DELETES_CEILING = 1000;
/// Rows per admin listUsers page, and the ceiling on a whole run's scan.
export const SWEEP_LIST_PAGE_SIZE = 200;
export const SWEEP_MAX_USERS_SCANNED = 10_000;
/// Ids per owner-lookup request. 36 chars each, so 50 keeps the PostgREST query
/// string comfortably short — an `in.(…)` list is a GET URL, not a body.
export const SWEEP_OWNER_QUERY_CHUNK = 50;
/// Rows per owner-lookup page. See `collectOwners` for why the page size is part
/// of the correctness argument and not a tuning knob.
export const SWEEP_OWNER_PAGE_SIZE = 200;

const DAY_MS = 86_400_000;

export type KeepReason =
  | "unreadable_created_at"
  | "too_young"
  | "signed_in_recently"
  | "touched_recently"
  | `has_${OwnedTable}`;

export const KEEP_REASONS: readonly KeepReason[] = [
  "unreadable_created_at",
  "too_young",
  "signed_in_recently",
  "touched_recently",
  ...OWNED_TABLES.map((t) => `has_${t}` as const),
];

/// The subset of the admin API's user record this decision needs. Nothing else
/// is read, and in particular the email never is — see the header.
export interface AuthUserLike {
  id: string;
  created_at?: string | null;
  last_sign_in_at?: string | null;
  updated_at?: string | null;
}

export interface SweepPlan {
  scanned: number;
  /// Ids that cleared every rule, capped at `maxDeletes`.
  deletable: string[];
  /// How many cleared every rule but did not fit under the cap; they come back
  /// on the next run.
  withheldByCap: number;
  kept: Record<KeepReason, number>;
}

export interface SweepParams {
  apply: boolean;
  minAgeDays: number;
  maxDeletes: number;
}

/// `{ apply: true }` — or its curl-friendly twin `{ apply: "true" }`, and
/// nothing else — arms the destructive half. Every other body — missing,
/// malformed, `{apply:"yes"}`, `{apply:1}` — is a report. (The string form is
/// accepted deliberately, for shells and workflow inputs that can't type a
/// JSON boolean; an auditor reasoning about what can arm this must count it.)
///
/// The numbers are CLAMPED rather than rejected, the same bargain
/// `parseRetentionDays` strikes: a cron config with a typo in it should run the
/// documented sweep, not a wilder one. Clamping `minAgeDays` upwards to the
/// floor is the safe direction; a non-number is still a 400, because silently
/// treating `"thirty"` as 30 would hide a broken scheduler forever.
export function sweepParams(body: unknown): SweepParams {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return {
      apply: false,
      minAgeDays: SWEEP_DEFAULT_MIN_AGE_DAYS,
      maxDeletes: SWEEP_DEFAULT_MAX_DELETES,
    };
  }
  const raw = body as Record<string, unknown>;
  return {
    apply: raw.apply === true || raw.apply === "true",
    minAgeDays: clampNumber(
      raw.minAgeDays,
      "minAgeDays",
      SWEEP_DEFAULT_MIN_AGE_DAYS,
      SWEEP_MIN_AGE_FLOOR_DAYS,
      SWEEP_MAX_MIN_AGE_DAYS,
    ),
    maxDeletes: clampNumber(
      raw.maxDeletes,
      "maxDeletes",
      SWEEP_DEFAULT_MAX_DELETES,
      0,
      SWEEP_MAX_DELETES_CEILING,
    ),
  };
}

function clampNumber(
  raw: unknown,
  field: string,
  fallback: number,
  min: number,
  max: number,
): number {
  if (raw === undefined || raw === null) return fallback;
  const value = typeof raw === "string" ? Number(raw) : raw;
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new HttpError(400, `invalid_${field}`, `${field} must be a number`);
  }
  return Math.min(max, Math.max(min, Math.trunc(value)));
}

/// The age/activity half of the verdict: a reason to keep, or null when the
/// timestamps clear this row for the ownership checks.
///
/// Absent is fine, unreadable is not. `created_at` is missing or unparseable →
/// keep, because we cannot age it. `last_sign_in_at` / `updated_at` are
/// legitimately null (an account that never signed in again), but a value we
/// cannot parse is treated as "just now" — the conservative reading of a field
/// whose whole job is to say "somebody is still using this".
///
/// Every comparison is inclusive of the boundary, so a row exactly `minAgeDays`
/// old is kept: at the one moment the answer is genuinely ambiguous, the tie
/// goes to the account.
export function timeKeepReason(
  user: AuthUserLike,
  nowMs: number,
  minAgeDays: number,
): KeepReason | null {
  const cutoff = nowMs - Math.max(minAgeDays, 0) * DAY_MS;

  const created = parseTime(user.created_at);
  if (created === null) return "unreadable_created_at";
  if (created >= cutoff) return "too_young";

  if (user.last_sign_in_at !== undefined && user.last_sign_in_at !== null) {
    const signedIn = parseTime(user.last_sign_in_at);
    if (signedIn === null || signedIn >= cutoff) return "signed_in_recently";
  }
  if (user.updated_at !== undefined && user.updated_at !== null) {
    const touched = parseTime(user.updated_at);
    if (touched === null || touched >= cutoff) return "touched_recently";
  }
  return null;
}

function parseTime(value: string | null | undefined): number | null {
  if (typeof value !== "string" || value.trim() === "") return null;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
}

/// The whole verdict, over every user the admin API handed back.
///
/// `owners` maps an account id to the first table found still holding a row for
/// it; the caller only has to look up the accounts that clear `timeKeepReason`,
/// because a row kept for its age never reaches the ownership question. Passing
/// a map that omits everyone else is therefore correct, not a shortcut.
export function planSweep(
  users: readonly AuthUserLike[],
  owners: ReadonlyMap<string, OwnedTable>,
  opts: { nowMs: number; minAgeDays: number; maxDeletes: number },
): SweepPlan {
  const kept = emptyTally();
  const deletable: string[] = [];
  let withheldByCap = 0;

  for (const user of users) {
    const timeReason = timeKeepReason(user, opts.nowMs, opts.minAgeDays);
    if (timeReason !== null) {
      kept[timeReason] += 1;
      continue;
    }
    const owned = owners.get(user.id);
    if (owned !== undefined) {
      kept[`has_${owned}`] += 1;
      continue;
    }
    if (deletable.length >= Math.max(opts.maxDeletes, 0)) {
      withheldByCap += 1;
      continue;
    }
    deletable.push(user.id);
  }

  return { scanned: users.length, deletable, withheldByCap, kept };
}

function emptyTally(): Record<KeepReason, number> {
  const tally = {} as Record<KeepReason, number>;
  for (const reason of KEEP_REASONS) tally[reason] = 0;
  return tally;
}

/// Which of `ids` still own a row, asked in pages, without a truncated answer
/// ever being able to widen the delete set.
///
/// The naive version — one `select … in (ids) limit N` — is a trap: a single
/// member with more than N posts fills the page on their own, every other id
/// comes back unmentioned, and "unmentioned" is exactly what this function
/// reports as "owns nothing". That is the one bug in this file that deletes a
/// real account, so the loop never infers anything from a FULL page: it removes
/// the ids it just saw and asks again. Only a SHORT page — fewer rows than the
/// limit — proves every remaining id was considered.
///
/// It terminates because a full page contains at least one row, every row names
/// an id still in `remaining`, and those ids are removed before the next pass.
/// The guard below is therefore unreachable; if a fetcher ever breaks that
/// invariant it throws rather than returning a set it cannot vouch for.
export async function collectOwners(
  ids: readonly string[],
  fetchPage: (
    ids: readonly string[],
    limit: number,
  ) => Promise<readonly string[]>,
  pageSize: number = SWEEP_OWNER_PAGE_SIZE,
): Promise<Set<string>> {
  const found = new Set<string>();
  if (ids.length === 0) return found;
  if (!Number.isFinite(pageSize) || pageSize < 1) {
    throw new Error(`page size must be >= 1, got ${pageSize}`);
  }

  let remaining: readonly string[] = ids;
  for (let guard = ids.length + 1; guard > 0; guard--) {
    const rows = await fetchPage(remaining, pageSize);
    for (const id of rows) found.add(id);
    if (rows.length < pageSize) return found;
    const next = remaining.filter((id) => !found.has(id));
    if (next.length === 0) return found;
    if (next.length === remaining.length) break; // no progress: fail closed
    remaining = next;
  }
  throw new Error("collectOwners did not converge");
}
