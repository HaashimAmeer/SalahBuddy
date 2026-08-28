// The nightly sweep, driven through `runRetention` against a fake client.
//
// Written mostly from the direction of what must NOT happen, because retention
// is the one scheduled job in the repo that deletes things people cannot get
// back:
//
//   * a confirmation must follow the Storage delete it confirms, never precede
//     it — the tombstone list is what makes a half-finished sweep resumable, and
//     forgetting a path Storage refused turns a retry into a permanent orphan;
//   * one bad batch must not strand the rest of the sweep;
//   * v5 §6's Live Activity token sweep runs LAST and must never be able to fail
//     the run. It is a backstop for phones that never came back — the photo
//     work is already done by the time it runs, and a 500 here would have the
//     scheduler retry a sweep whose destructive half already succeeded.
//
// That last one is why this file exists at all. The token sweep swallows its
// error and returns 0, which is a contract no type states and nothing enforced
// until now: it lived beside a top-level `Deno.serve`, so no permission-less
// test could import it, and turning the swallow into a `throw` left every test
// in the suite green.

import assert from "node:assert/strict";
import {
  PHOTO_BUCKET,
  runRetention,
  STORAGE_REMOVE_CHUNK,
  sweepLiveActivityTokens,
} from "../../supabase/functions/retention/handlers.ts";
import { HttpError } from "../../supabase/functions/_shared/http.ts";
import { FakeSupabase } from "./fake_supabase.ts";

const OPTS = { days: 30, minIntervalMinutes: 60 };

/// A client whose leases and sweeps all succeed, so a test only has to describe
/// the one thing it is about.
function db(opts: {
  claimed?: boolean;
  paths?: string[];
  tokensCleared?: unknown;
} = {}): FakeSupabase {
  const fake = new FakeSupabase();
  fake.rpcResults.set("claim_retention_run", {
    data: opts.claimed ?? true,
    error: null,
  });
  fake.rpcResults.set("purge_expired_photo_rows", {
    data: opts.paths ?? [],
    error: null,
  });
  fake.rpcResults.set("confirm_photo_deletions", { data: null, error: null });
  fake.rpcResults.set("purge_expired_live_activity_tokens", {
    data: opts.tokensCleared ?? 0,
    error: null,
  });
  return fake;
}

function rpcNames(fake: FakeSupabase): string[] {
  return fake.rpcCalls.map((call) => call.fn);
}

// --------------------------------------------------------------- the lease

Deno.test("a run another tick already claimed does no work at all", async () => {
  const fake = db({ claimed: false, paths: ["a/1.jpg"], tokensCleared: 9 });
  const result = await runRetention(fake.asClient(), OPTS);

  assert.deepEqual(result, {
    ok: true,
    skipped: true,
    reason: "claimed_recently",
  });
  // Not the photos, and not the tokens either: two overlapping cron ticks must
  // not both purge, and "both" includes the half that was added later.
  assert.deepEqual(rpcNames(fake), ["claim_retention_run"]);
  assert.equal(fake.removals.length, 0);
});

Deno.test("a failed lease is a 500, not a silent skip", async () => {
  const fake = db();
  fake.rpcResults.set("claim_retention_run", {
    data: null,
    error: { message: "deadlock detected" },
  });
  await assert.rejects(
    () => runRetention(fake.asClient(), OPTS),
    (err: unknown) =>
      err instanceof HttpError && err.status === 500 &&
      err.code === "claim_failed",
  );
});

// -------------------------------------------------------------- the photos

Deno.test("objects are removed, then confirmed — in that order", async () => {
  const fake = db({ paths: ["u1/a.jpg", "u2/b.jpg"] });
  const result = await runRetention(fake.asClient(), OPTS);

  assert.equal(result.photoRowsCleared, 2);
  assert.equal(result.objectsRemoved, 2);
  assert.equal(result.pendingRetry, 0);
  assert.deepEqual(result.storageErrors, []);
  assert.deepEqual(fake.removals, [{
    bucket: PHOTO_BUCKET,
    paths: ["u1/a.jpg", "u2/b.jpg"],
  }]);
  // The confirmation comes AFTER the purge that produced the paths and after
  // the delete it confirms. Reading the rpc order is the only way to say so:
  // the paths live in a tombstone table precisely so a failed delete leaves
  // them on the list.
  assert.deepEqual(rpcNames(fake), [
    "claim_retention_run",
    "purge_expired_photo_rows",
    "confirm_photo_deletions",
    "purge_expired_live_activity_tokens",
  ]);
});

Deno.test("a batch Storage refused is neither confirmed nor fatal", async () => {
  const fake = db({ paths: ["u1/a.jpg"] });
  fake.removeResult = () => ({ data: [], error: { message: "bucket offline" } });

  const result = await runRetention(fake.asClient(), OPTS);

  assert.equal(result.ok, true);
  assert.equal(result.objectsRemoved, 0);
  // Still owed, so the next tick picks it up — the whole point of confirming
  // only what Storage accepted.
  assert.equal(result.pendingRetry, 1);
  assert.deepEqual(result.storageErrors, ["bucket offline"]);
  assert.ok(!rpcNames(fake).includes("confirm_photo_deletions"));
});

Deno.test("one bad batch does not strand the ones after it", async () => {
  const paths = Array.from(
    { length: STORAGE_REMOVE_CHUNK + 2 },
    (_unused, i) => `u/${i}.jpg`,
  );
  const fake = db({ paths });
  let batch = 0;
  fake.removeResult = (_bucket, batchPaths) => {
    batch += 1;
    return batch === 1
      ? { data: [], error: { message: "first batch failed" } }
      : { data: batchPaths.map((name) => ({ name })), error: null };
  };

  const result = await runRetention(fake.asClient(), OPTS);

  assert.equal(fake.removals.length, 2);
  assert.equal(result.objectsRemoved, 2);
  assert.equal(result.pendingRetry, STORAGE_REMOVE_CHUNK);
  assert.deepEqual(result.storageErrors, ["first batch failed"]);
});

// ------------------------------------------------- v5 §6, the token backstop

Deno.test("the live activity token sweep runs, and reports what it cleared", async () => {
  const fake = db({ tokensCleared: 7 });
  const result = await runRetention(fake.asClient(), OPTS);

  assert.equal(result.liveActivityTokensCleared, 7);
  assert.ok(rpcNames(fake).includes("purge_expired_live_activity_tokens"));
});

Deno.test("the token sweep runs LAST, after the photos are confirmed", async () => {
  const fake = db({ paths: ["u1/a.jpg"], tokensCleared: 1 });
  await runRetention(fake.asClient(), OPTS);

  const names = rpcNames(fake);
  assert.equal(names.at(-1), "purge_expired_live_activity_tokens");
  assert.ok(
    names.indexOf("confirm_photo_deletions") <
      names.indexOf("purge_expired_live_activity_tokens"),
    "the photo half must be finished before the backstop is attempted",
  );
});

Deno.test("a failed token sweep never fails the run", async () => {
  const fake = db({ paths: ["u1/a.jpg"] });
  fake.rpcResults.set("purge_expired_live_activity_tokens", {
    data: null,
    error: { message: "permission denied for function" },
  });

  // NOT a rejection. A throw here would turn a successful photo sweep into a
  // 500 the scheduler retries — re-running the destructive half for the sake of
  // a backstop whose rows are still expired and still there next tick.
  const result = await runRetention(fake.asClient(), OPTS);

  assert.equal(result.ok, true);
  assert.equal(result.skipped, false);
  assert.equal(result.liveActivityTokensCleared, 0);
  // ...and the photo half still reports honestly, which is the reason the
  // swallow exists rather than being tidiness.
  assert.equal(result.photoRowsCleared, 1);
  assert.equal(result.objectsRemoved, 1);
  assert.equal(result.pendingRetry, 0);
});

Deno.test("a token sweep that answers something other than a number reads as zero", async () => {
  // PostgREST hands `returns int` back as a number, but an rpc that was renamed
  // away, or a client version that wraps it, must not put `null` or a string
  // into a count the scheduler logs.
  for (const data of [null, undefined, "3", { count: 3 }, []]) {
    const fake = db();
    fake.rpcResults.set("purge_expired_live_activity_tokens", {
      data,
      error: null,
    });
    assert.equal(await sweepLiveActivityTokens(fake.asClient()), 0);
  }
  const fake = db({ tokensCleared: 4 });
  assert.equal(await sweepLiveActivityTokens(fake.asClient()), 4);
});
