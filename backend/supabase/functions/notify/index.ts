// notify — circle push notifications (SPEC-V4 §6).
//
// `verify_jwt = true`: the caller's own user JWT authenticates them, so this
// function carries NO repo-managed secret. The platform verifies the signature;
// we then re-derive everything that matters from the database with the
// service-role key. The body only says what the caller CLAIMS — who they are,
// what circle they're in, whether they own that post and whether the nudge is
// rate-limited are all answered by Postgres.
//
// POST body, one of:
//   { "kind": "post",  "postId": "<uuid>" }
//   { "kind": "join" }
//   { "kind": "nudge", "recipientId": "<uuid>", "dayKey": "yyyy-MM-dd",
//     "prayer": "fajr|dhuhr|asr|maghrib|isha" }
//
// Always answers 200 with a JSON body describing what happened; 400 for a
// malformed body and 401 for a bearer we cannot resolve to a user.
//
// THE SOCKET AND NOTHING ELSE. Every line of the work lives in ./handlers.ts,
// because a module with a top-level `Deno.serve` cannot be imported by a test
// that runs without --allow-net, and the §6 rule that only a POST fan-out is
// relevance-filtered is enforced by nothing but which call site passes it.
// Logic that lands in this file is logic `tests/deno/notify_test.ts` cannot see.

import { errorResponse, handleOptions } from "../_shared/http.ts";
import { handle } from "./handlers.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  try {
    return await handle(req);
  } catch (err) {
    return errorResponse(err);
  }
});
