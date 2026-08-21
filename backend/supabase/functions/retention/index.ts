// retention — the ~30-day photo purge (SPEC-V4 §4).
//
// `verify_jwt = true`, and any authenticated identity may trigger it: the
// scheduled caller (service_role) in normal operation, a signed-in developer
// when we want to force a sweep. There is nothing user-specific to authorise —
// the work is a fixed, idempotent, whole-project cleanup.
//
// Order matters: claim the run slot FIRST (a single row + `for update`, so two
// overlapping cron ticks cannot both purge), then let SQL retract the expired
// rows and hand back the pending object paths, then delete those objects from
// Storage — and only then tell the database they are gone.
//
// That last step is the difference between "swept next run" being true and being
// a comforting sentence in a comment. The paths live in a tombstone table, not
// in the return value of the statement that erased them, so a batch that fails
// (or a run the wall clock kills mid-loop) leaves them on the list and the next
// tick picks them up. Confirming only what Storage accepted is what makes a
// half-finished sweep resumable instead of a permanent orphan.
//
// POST body (all optional): { "days": 30, "minIntervalMinutes": 60 }

import { bearerToken, isServiceRoleToken } from "../_shared/auth.ts";
import {
  type Client,
  resolveCallerId,
  serviceClient,
  SUPABASE_SERVICE_ROLE_KEY_ENV,
} from "../_shared/db.ts";
import {
  errorResponse,
  handleOptions,
  HttpError,
  json,
  readJsonBody,
  requireMethod,
} from "../_shared/http.ts";
import {
  normalizePhotoPaths,
  retentionInterval,
  retentionParams,
} from "../_shared/validate.ts";
import { chunk, readEnv } from "../_shared/util.ts";

export const PHOTO_BUCKET = "prayer-photos";
/// Supabase Storage caps a single remove() call; 100 keeps us well inside it.
export const STORAGE_REMOVE_CHUNK = 100;
/// Paths per run. Bounded so the first sweep after a long gap cannot return an
/// unbounded set and guarantee the timeout it exists to prevent — the remainder
/// is simply picked up on the next tick.
export const PURGE_BATCH_LIMIT = 500;

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  try {
    return await handle(req);
  } catch (err) {
    return errorResponse(err);
  }
});

async function handle(req: Request): Promise<Response> {
  requireMethod(req, ["POST", "GET"]);

  const jwt = bearerToken(req.headers.get("Authorization"));
  if (!jwt) throw new HttpError(401, "missing_authorization");

  const body = req.method === "POST" ? await readJsonBody(req) : {};

  const admin = serviceClient();
  const serviceRole = isServiceRoleToken(
    jwt,
    readEnv(SUPABASE_SERVICE_ROLE_KEY_ENV),
  );
  if (!serviceRole) {
    const callerId = await resolveCallerId(admin, jwt);
    if (!callerId) throw new HttpError(401, "invalid_token");
  }
  // A signed-in human may trigger the sweep but not retune it (see
  // retentionParams) — the body's knobs are the scheduler's alone.
  const { days, minIntervalMinutes } = retentionParams(body, { serviceRole });

  const { data: claimed, error: claimError } = await admin.rpc(
    "claim_retention_run",
    { p_min_interval: retentionInterval(minIntervalMinutes) },
  );
  if (claimError) {
    throw new HttpError(500, "claim_failed", claimError.message);
  }
  if (claimed !== true) {
    return json({ ok: true, skipped: true, reason: "claimed_recently" });
  }

  const { data: purged, error: purgeError } = await admin.rpc(
    "purge_expired_photo_rows",
    { p_days: days, p_limit: PURGE_BATCH_LIMIT },
  );
  if (purgeError) {
    throw new HttpError(500, "purge_failed", purgeError.message);
  }

  const paths = normalizePhotoPaths(purged);
  const { removed, confirmed, errors } = await removeObjects(admin, paths);

  return json({
    ok: true,
    skipped: false,
    days,
    photoRowsCleared: paths.length,
    objectsRemoved: removed,
    // paths still pending come back on the next run; nothing is lost
    pendingRetry: paths.length - confirmed,
    storageErrors: errors,
  });
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
