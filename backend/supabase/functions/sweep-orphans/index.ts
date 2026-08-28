// sweep-orphans — delete the `auth.users` shells `delete_account()` leaves
// behind (backend/README.md, "TODO before production").
//
// `delete_account()` erases every row a user owns and then stops: removing the
// account itself needs the service-role admin API, which no client holds. So the
// shells accumulate — one per real deletion, three per staging push from the
// smoke job's throwaway users. The circles those users created are already
// handled: once the last membership goes the circle is empty, and retention's
// step 3b drops it seven days later.
//
// SERVICE ROLE ONLY, unlike `retention`. A signed-in developer may force a photo
// sweep because the work is a fixed, idempotent cleanup; this one enumerates
// every account in the project on every call, which is both a real cost and a
// shape no user session should be able to trigger. The bearer must therefore BE
// the project's service-role key — `isServiceRoleToken` compares it verbatim
// against the injected `SUPABASE_SERVICE_ROLE_KEY` and never trusts a decoded
// `role` claim (see _shared/auth.ts for why that distinction is load-bearing).
//
// Two modes, and REPORT IS THE DEFAULT: a bare POST counts what it would delete
// and deletes nothing. Only `{"apply": true}` arms it. The criteria that decide
// a row's fate — and the argument for why they cannot reach a live account —
// live in _shared/sweep.ts, which is where to look before changing any of this.
//
// POST body (all optional): { "apply": false, "minAgeDays": 30, "maxDeletes": 100 }

import { bearerToken, isServiceRoleToken } from "../_shared/auth.ts";
import {
  type Client,
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
  type AuthUserLike,
  collectOwners,
  OWNED_TABLE_COLUMN,
  OWNED_TABLES,
  type OwnedTable,
  planSweep,
  SWEEP_LIST_PAGE_SIZE,
  SWEEP_MAX_USERS_SCANNED,
  SWEEP_OWNER_PAGE_SIZE,
  SWEEP_OWNER_QUERY_CHUNK,
  sweepParams,
  timeKeepReason,
} from "../_shared/sweep.ts";
import { chunk, readEnv } from "../_shared/util.ts";

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
  if (!isServiceRoleToken(jwt, readEnv(SUPABASE_SERVICE_ROLE_KEY_ENV))) {
    throw new HttpError(403, "service_role_required");
  }

  const body = req.method === "POST" ? await readJsonBody(req) : {};
  const { apply, minAgeDays, maxDeletes } = sweepParams(body);
  const admin = serviceClient();
  const nowMs = Date.now();

  const { users, capped } = await listUsers(admin);

  // Only the accounts that clear the age/activity rules are worth a database
  // round trip, and each table is asked about the ids still unaccounted for —
  // `profiles` answers for nearly all of them in one query.
  const owners = new Map<string, OwnedTable>();
  const candidates = users
    .filter((u) => timeKeepReason(u, nowMs, minAgeDays) === null)
    .map((u) => u.id);
  for (const table of OWNED_TABLES) {
    const unresolved = candidates.filter((id) => !owners.has(id));
    if (unresolved.length === 0) break;
    for (const id of await ownersIn(admin, table, unresolved)) {
      if (!owners.has(id)) owners.set(id, table);
    }
  }

  const plan = planSweep(users, owners, { nowMs, minAgeDays, maxDeletes });

  let deleted = 0;
  let deleteErrors = 0;
  if (apply) {
    for (const id of plan.deletable) {
      const { error } = await admin.auth.admin.deleteUser(id);
      if (error) {
        // One stubborn row must not strand the rest; it simply comes back in
        // the next run's report.
        console.error("sweep-orphans: delete failed", id, error.message);
        deleteErrors += 1;
        continue;
      }
      deleted += 1;
    }
  }

  // COUNTS ONLY. The scheduled caller is a GitHub Actions job on a PUBLIC repo,
  // so this body lands in a log anyone can read: ids and addresses stay in the
  // function's own logs (`console.error` above), which are not public. The
  // tallies are enough to see the sweep behaving and to spot the day a number
  // moves unexpectedly, which is the whole point of running it in report mode
  // first.
  return json({
    ok: true,
    apply,
    minAgeDays,
    maxDeletes,
    scanned: plan.scanned,
    scanCapped: capped,
    deletable: plan.deletable.length,
    withheldByCap: plan.withheldByCap,
    deleted,
    deleteErrors,
    kept: plan.kept,
  });
}

/// Every account, in admin-API pages, bounded so one runaway call cannot outlive
/// the function's wall clock. Hitting the cap is reported, never silent: the
/// sweep is still correct (it only ever deletes rows it looked at), it just has
/// more to do next time.
async function listUsers(
  admin: Client,
): Promise<{ users: AuthUserLike[]; capped: boolean }> {
  const users: AuthUserLike[] = [];
  for (let page = 1;; page++) {
    const { data, error } = await admin.auth.admin.listUsers({
      page,
      perPage: SWEEP_LIST_PAGE_SIZE,
    });
    if (error) throw new HttpError(500, "list_users_failed", error.message);
    const batch = data?.users ?? [];
    for (const user of batch) {
      users.push({
        id: user.id,
        created_at: user.created_at,
        last_sign_in_at: user.last_sign_in_at,
        updated_at: user.updated_at,
      });
    }
    if (batch.length < SWEEP_LIST_PAGE_SIZE) return { users, capped: false };
    if (users.length >= SWEEP_MAX_USERS_SCANNED) return { users, capped: true };
  }
}

/// Which of `ids` still own a row in `table`.
///
/// Chunked because an `in.(…)` filter is a GET query string, and paged inside
/// each chunk because a truncated page must never read as "owns nothing" — see
/// `collectOwners`, which carries that argument in full.
async function ownersIn(
  admin: Client,
  table: OwnedTable,
  ids: readonly string[],
): Promise<Set<string>> {
  const column = OWNED_TABLE_COLUMN[table];
  const found = new Set<string>();
  for (const group of chunk(ids, SWEEP_OWNER_QUERY_CHUNK)) {
    const owners = await collectOwners(group, async (batch, limit) => {
      const { data, error } = await admin
        .from(table)
        .select(column)
        .in(column, batch as string[])
        .limit(limit);
      if (error) {
        throw new HttpError(500, "owner_lookup_failed", error.message);
      }
      // `column` is a runtime value, so supabase-js cannot type the row shape
      // and infers its "unparseable select" branch — hence the trip through
      // `unknown`. The cast is safe by construction: the select names exactly
      // one column and the query errored otherwise.
      return ((data ?? []) as unknown as Record<string, unknown>[])
        .map((row) => String(row[column]));
    }, SWEEP_OWNER_PAGE_SIZE);
    for (const id of owners) found.add(id);
  }
  return found;
}
