// retention's handlers — everything the endpoint does, minus the socket.
//
// Split out for the reason `notify/handlers.ts` was: a module with a top-level
// `Deno.serve` cannot be imported by a test that runs without --allow-net, so
// every line that lived beside one was a line `backend/tests/deno/` could not
// see. That was fine while this function was one loop over Storage; it stopped
// being fine when v5 §6 hung a second sweep off the end of it, with a `try`-less
// error swallow whose whole contract is "a failure here must NOT fail the run".
// A swallow nothing tests is a swallow somebody turns into a `throw` during a
// tidy-up, and the symptom is a nightly job that 500s and gets retried after it
// has already deleted the photos.
//
// `runRetention` takes its `admin` client as a parameter — the same shape the
// three notify handlers have, and the same reason.

import { type Client } from "../_shared/db.ts";
import { HttpError } from "../_shared/http.ts";
import { normalizePhotoPaths, retentionInterval } from "../_shared/validate.ts";
import { chunk } from "../_shared/util.ts";

export const PHOTO_BUCKET = "prayer-photos";
/// Supabase Storage caps a single remove() call; 100 keeps us well inside it.
export const STORAGE_REMOVE_CHUNK = 100;
/// Paths per run. Bounded so the first sweep after a long gap cannot return an
/// unbounded set and guarantee the timeout it exists to prevent — the remainder
/// is simply picked up on the next tick.
export const PURGE_BATCH_LIMIT = 500;

/// What a run answers with. `skipped` runs carry nothing else: another tick
/// holds the lease and this one did no work to report.
export interface RetentionResult {
  ok: true;
  skipped: boolean;
  reason?: string;
  days?: number;
  photoRowsCleared?: number;
  objectsRemoved?: number;
  pendingRetry?: number;
  storageErrors?: string[];
  liveActivityTokensCleared?: number;
}

/// The whole run, against a client the caller supplies.
///
/// Order matters and is the point of the function: claim the run slot FIRST (a
/// single row + `for update`, so two overlapping cron ticks cannot both purge),
/// then let SQL retract the expired rows and hand back the pending object paths,
/// then delete those objects from Storage — and only then tell the database they
/// are gone. Confirming only what Storage accepted is what makes a half-finished
/// sweep resumable instead of a permanent orphan.
export async function runRetention(
  admin: Client,
  opts: { days: number; minIntervalMinutes: number },
): Promise<RetentionResult> {
  const { data: claimed, error: claimError } = await admin.rpc(
    "claim_retention_run",
    { p_min_interval: retentionInterval(opts.minIntervalMinutes) },
  );
  if (claimError) {
    throw new HttpError(500, "claim_failed", claimError.message);
  }
  if (claimed !== true) {
    return { ok: true, skipped: true, reason: "claimed_recently" };
  }

  const { data: purged, error: purgeError } = await admin.rpc(
    "purge_expired_photo_rows",
    { p_days: opts.days, p_limit: PURGE_BATCH_LIMIT },
  );
  if (purgeError) {
    throw new HttpError(500, "purge_failed", purgeError.message);
  }

  const paths = normalizePhotoPaths(purged);
  const { removed, confirmed, errors } = await removeObjects(admin, paths);

  return {
    ok: true,
    skipped: false,
    days: opts.days,
    photoRowsCleared: paths.length,
    objectsRemoved: removed,
    // paths still pending come back on the next run; nothing is lost
    pendingRetry: paths.length - confirmed,
    storageErrors: errors,
    liveActivityTokensCleared: await sweepLiveActivityTokens(admin),
  };
}

/// v5 §6 — the Live Activity token backstop.
///
/// A window closing is the client's job: the app ends its activity and deletes
/// its own row (`live_activity_tokens_all` scopes that to its own rows, so no
/// RPC is needed). This is for every phone that never came back to do it —
/// uninstalled, out of battery, signed out offline, killed mid-window. Without
/// it the table is append-only and every future fan-out pays a round trip to
/// Apple for phones that stopped listening months ago.
///
/// LAST, and NEVER FATAL. The photo sweep is the reason this function exists and
/// has already done its work by the time we get here; a token sweep that failed
/// must not turn a successful retention run into a 500 the scheduler retries —
/// the rows are still expired, and the next tick collects them. That is a
/// property, not a comment: `retention_test.ts` drives a failing RPC through
/// `runRetention` and asserts the photo half still reports.
export async function sweepLiveActivityTokens(admin: Client): Promise<number> {
  const { data, error } = await admin.rpc(
    "purge_expired_live_activity_tokens",
  );
  if (error) {
    console.error("retention: live activity sweep failed", error.message);
    return 0;
  }
  return typeof data === "number" ? data : 0;
}

async function removeObjects(
  admin: Client,
  paths: readonly string[],
): Promise<{ removed: number; confirmed: number; errors: string[] }> {
  let removed = 0;
  let confirmed = 0;
  const errors: string[] = [];
  for (const batch of chunk(paths, STORAGE_REMOVE_CHUNK)) {
    const { data, error } = await admin.storage.from(PHOTO_BUCKET).remove(
      batch,
    );
    if (error) {
      // Keep going: one bad batch must not strand the rest of the sweep. The
      // batch stays on the tombstone list, so the next run retries it.
      console.error("retention: storage remove failed", error.message);
      errors.push(error.message);
      continue;
    }
    removed += data?.length ?? batch.length;

    // Only now is it safe to forget the paths.
    const { error: confirmError } = await admin.rpc("confirm_photo_deletions", {
      p_paths: batch,
    });
    if (confirmError) {
      console.error("retention: confirm failed", confirmError.message);
      errors.push(confirmError.message);
      continue;
    }
    confirmed += batch.length;
  }
  return { removed, confirmed, errors };
}
