// retention — the ~30-day photo purge (SPEC-V4 §4), plus v5 §6's Live Activity
// token backstop.
//
// `verify_jwt = true`, and any authenticated identity may trigger it: the
// scheduled caller (service_role) in normal operation, a signed-in developer
// when we want to force a sweep. There is nothing user-specific to authorise —
// the work is a fixed, idempotent, whole-project cleanup.
//
// POST body (all optional): { "days": 30, "minIntervalMinutes": 60 }
//
// THE SOCKET AND THE DOOR, AND NOTHING ELSE. The work lives in ./handlers.ts
// because a module with a top-level `Deno.serve` cannot be imported by a test
// that runs without --allow-net — the same split, for the same reason, as
// notify/. What stays here is authentication and the two knobs, both of which
// need the environment; what moved is everything a test can drive with a fake
// client, including the order the sweeps run in and the token sweep's
// deliberately non-fatal failure.

import { bearerToken, isServiceRoleToken } from "../_shared/auth.ts";
import {
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
import { retentionParams } from "../_shared/validate.ts";
import { readEnv } from "../_shared/util.ts";
import { runRetention } from "./handlers.ts";

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

  return json(await runRetention(admin, { days, minIntervalMinutes }));
}
