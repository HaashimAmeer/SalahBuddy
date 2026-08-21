// retention — the ~30-day photo purge (SPEC-V4 §4).
//
// `verify_jwt = true`, and any authenticated identity may trigger it: the
// scheduled caller (service_role) in normal operation, a signed-in developer
// when we want to force a sweep. There is nothing user-specific to authorise —
// the work is a fixed, idempotent, whole-project cleanup.
//
// Order matters: claim the run slot FIRST (a single row + `for update`, so two
// overlapping cron ticks cannot both purge), then let SQL null out the expired
// `photo_path`s and hand back the object paths, then delete those objects from
// Storage. Rows first means a crash mid-delete leaves orphaned objects (harmless,
// swept next run) rather than posts pointing at photos that no longer exist.
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
    { p_days: days },
  );
  if (purgeError) {
    throw new HttpError(500, "purge_failed", purgeError.message);
  }

  const paths = normalizePhotoPaths(purged);
  const { removed, errors } = await removeObjects(admin, paths);

  return json({
    ok: true,
    skipped: false,
    days,
    photoRowsCleared: paths.length,
    objectsRemoved: removed,
    storageErrors: errors,
  });
}

async function removeObjects(
  admin: Client,
  paths: readonly string[],
): Promise<{ removed: number; errors: string[] }> {
  let removed = 0;
  const errors: string[] = [];
  for (const batch of chunk(paths, STORAGE_REMOVE_CHUNK)) {
    const { data, error } = await admin.storage.from(PHOTO_BUCKET).remove(
      batch,
    );
    if (error) {
      // Keep going: one bad batch must not strand the rest of the sweep.
      console.error("retention: storage remove failed", error.message);
      errors.push(error.message);
      continue;
    }
    removed += data?.length ?? batch.length;
  }
  return { removed, errors };
}
