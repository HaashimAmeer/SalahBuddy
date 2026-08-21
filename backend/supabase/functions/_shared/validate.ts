// Request-body validation for `notify`.
//
// The body is attacker-controlled: it tells us what the caller CLAIMS to have
// done. This module only proves the shape is well formed; ownership,
// membership and rate limiting are all re-derived from the database in
// notify/index.ts. Pure and exported so the tests can hammer it offline.

import { HttpError } from "./http.ts";

/// Must match the `prayer_kind` enum and Swift's `Prayer` rawValues exactly.
export const PRAYERS = ["fajr", "dhuhr", "asr", "maghrib", "isha"] as const;
export type PrayerKind = typeof PRAYERS[number];

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/// `dayKey` is the client-computed SCHEDULE day ("yyyy-MM-dd", local time).
const DAY_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

export const NOTIFY_KINDS = ["post", "join", "nudge"] as const;
export type NotifyKind = typeof NOTIFY_KINDS[number];

export type NotifyRequest =
  | { kind: "post"; postId: string }
  | { kind: "join" }
  | {
    kind: "nudge";
    recipientId: string;
    dayKey: string;
    prayer: PrayerKind;
  };

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

export function isDayKey(value: unknown): value is string {
  if (typeof value !== "string" || !DAY_KEY_RE.test(value)) return false;
  // Reject "2026-13-40": the same string is a CHECK-constrained key in Postgres,
  // so a bad one would only blow up later, deeper in.
  const [y, m, d] = value.split("-").map(Number);
  if (m < 1 || m > 12 || d < 1 || d > 31) return false;
  const date = new Date(Date.UTC(y, m - 1, d));
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 &&
    date.getUTCDate() === d;
}

export function isPrayerKind(value: unknown): value is PrayerKind {
  return typeof value === "string" &&
    (PRAYERS as readonly string[]).includes(value);
}

export function prayerDisplayName(prayer: PrayerKind): string {
  return prayer.charAt(0).toUpperCase() + prayer.slice(1);
}

/// Narrows an arbitrary JSON body to a NotifyRequest, or throws HttpError(400).
export function parseNotifyRequest(body: unknown): NotifyRequest {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw new HttpError(400, "invalid_body", "body must be a JSON object");
  }
  const raw = body as Record<string, unknown>;
  const kind = raw.kind;
  if (!isNotifyKind(kind)) {
    throw new HttpError(
      400,
      "invalid_kind",
      `kind must be one of ${NOTIFY_KINDS.join(", ")}`,
    );
  }

  switch (kind) {
    case "post": {
      if (!isUuid(raw.postId)) {
        throw new HttpError(400, "invalid_post_id", "postId must be a uuid");
      }
      return { kind: "post", postId: raw.postId.toLowerCase() };
    }
    case "join":
      return { kind: "join" };
    case "nudge": {
      if (!isUuid(raw.recipientId)) {
        throw new HttpError(
          400,
          "invalid_recipient_id",
          "recipientId must be a uuid",
        );
      }
      if (!isDayKey(raw.dayKey)) {
        throw new HttpError(
          400,
          "invalid_day_key",
          "dayKey must be yyyy-MM-dd",
        );
      }
      if (!isPrayerKind(raw.prayer)) {
        throw new HttpError(
          400,
          "invalid_prayer",
          `prayer must be one of ${PRAYERS.join(", ")}`,
        );
      }
      return {
        kind: "nudge",
        recipientId: raw.recipientId.toLowerCase(),
        dayKey: raw.dayKey,
        prayer: raw.prayer,
      };
    }
  }
}

function isNotifyKind(value: unknown): value is NotifyKind {
  return typeof value === "string" &&
    (NOTIFY_KINDS as readonly string[]).includes(value);
}

/// Retention accepts an optional `{ days }`; clamp rather than reject so a
/// fat-fingered cron config cannot wipe fresh photos.
export const RETENTION_DEFAULT_DAYS = 30;
export const RETENTION_MIN_DAYS = 1;
export const RETENTION_MAX_DAYS = 3650;

export function parseRetentionDays(body: unknown): number {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return RETENTION_DEFAULT_DAYS;
  }
  const raw = (body as Record<string, unknown>).days;
  if (raw === undefined || raw === null) return RETENTION_DEFAULT_DAYS;
  const days = typeof raw === "string" ? Number(raw) : raw;
  if (typeof days !== "number" || !Number.isFinite(days)) {
    throw new HttpError(400, "invalid_days", "days must be a number");
  }
  const rounded = Math.trunc(days);
  return Math.min(RETENTION_MAX_DAYS, Math.max(RETENTION_MIN_DAYS, rounded));
}

/// `claim_retention_run` takes a minimum interval between runs. Callers may
/// pass `{ minIntervalMinutes }` (0 = force a run); anything silly is clamped.
export const RETENTION_DEFAULT_MINUTES = 60;
export const RETENTION_MAX_MINUTES = 7 * 24 * 60;

export function parseRetentionMinutes(body: unknown): number {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return RETENTION_DEFAULT_MINUTES;
  }
  const raw = (body as Record<string, unknown>).minIntervalMinutes;
  if (raw === undefined || raw === null) return RETENTION_DEFAULT_MINUTES;
  const minutes = typeof raw === "string" ? Number(raw) : raw;
  if (typeof minutes !== "number" || !Number.isFinite(minutes)) {
    throw new HttpError(
      400,
      "invalid_min_interval",
      "minIntervalMinutes must be a number",
    );
  }
  return Math.min(RETENTION_MAX_MINUTES, Math.max(0, Math.trunc(minutes)));
}

/// Formats those minutes as a Postgres interval literal.
export function retentionInterval(minutes: number): string {
  return `${minutes} minutes`;
}

/// The sweep's knobs, gated by who is calling.
///
/// Retention is destructive: `days` decides how old a photo has to be before it
/// is deleted. Only the scheduler (service_role) may tune it — otherwise any
/// signed-in user could POST `{days: 1}` and wipe every circle's fresh photos.
/// Everyone else silently gets the documented defaults.
export function retentionParams(
  body: unknown,
  opts: { serviceRole: boolean },
): { days: number; minIntervalMinutes: number } {
  if (!opts.serviceRole) {
    return {
      days: RETENTION_DEFAULT_DAYS,
      minIntervalMinutes: RETENTION_DEFAULT_MINUTES,
    };
  }
  return {
    days: parseRetentionDays(body),
    minIntervalMinutes: parseRetentionMinutes(body),
  };
}

/// `purge_expired_photo_rows` returns `setof text`. PostgREST renders that as a
/// bare string array, but a single-column set can also arrive as objects
/// depending on the client version — normalise both, drop anything empty.
export function normalizePhotoPaths(data: unknown): string[] {
  if (data === null || data === undefined) return [];
  const rows = Array.isArray(data) ? data : [data];
  const paths: string[] = [];
  for (const row of rows) {
    if (typeof row === "string") {
      if (row.trim() !== "") paths.push(row);
      continue;
    }
    if (row !== null && typeof row === "object") {
      for (const value of Object.values(row as Record<string, unknown>)) {
        if (typeof value === "string" && value.trim() !== "") paths.push(value);
      }
    }
  }
  return paths;
}
