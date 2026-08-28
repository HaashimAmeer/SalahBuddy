// The orphan sweep decides whether to delete somebody's account, so these tests
// are written from the other direction to most: every case that must NEVER be
// swept comes first, and the "it actually deletes something" cases are last.
//
// Nothing here touches the network. `collectOwners` takes its page fetcher as an
// argument precisely so the paging argument — a truncated page must never read
// as "owns nothing" — can be hammered offline.

import assert from "node:assert/strict";
import {
  type AuthUserLike,
  collectOwners,
  KEEP_REASONS,
  OWNED_TABLE_COLUMN,
  OWNED_TABLES,
  type OwnedTable,
  planSweep,
  SWEEP_DEFAULT_MAX_DELETES,
  SWEEP_DEFAULT_MIN_AGE_DAYS,
  SWEEP_MAX_DELETES_CEILING,
  SWEEP_MAX_MIN_AGE_DAYS,
  SWEEP_MIN_AGE_FLOOR_DAYS,
  sweepParams,
  timeKeepReason,
} from "../../supabase/functions/_shared/sweep.ts";
import { HttpError } from "../../supabase/functions/_shared/http.ts";

const NOW = Date.parse("2026-08-27T12:00:00Z");
const DAY = 86_400_000;

function ago(days: number): string {
  return new Date(NOW - days * DAY).toISOString();
}

/// An account with nothing left of it: the shape `delete_account()` leaves
/// behind once the CI smoke job has signed out.
function orphan(id: string, ageDays = 90): AuthUserLike {
  return { id, created_at: ago(ageDays), last_sign_in_at: null };
}

function plan(
  users: readonly AuthUserLike[],
  owners: ReadonlyMap<string, OwnedTable> = new Map(),
  opts: Partial<{ minAgeDays: number; maxDeletes: number }> = {},
) {
  return planSweep(users, owners, {
    nowMs: NOW,
    minAgeDays: opts.minAgeDays ?? SWEEP_DEFAULT_MIN_AGE_DAYS,
    maxDeletes: opts.maxDeletes ?? SWEEP_DEFAULT_MAX_DELETES,
  });
}

// ------------------------------------------------ accounts that must survive

Deno.test("a live account is never swept, however old and however quiet", () => {
  // The load-bearing rule: `on_auth_user_created` gives every account a profile
  // and `authenticated` holds no DELETE on profiles, so a profile row IS a live
  // account — even one that signed up years ago and has not opened the app
  // since.
  const ancient: AuthUserLike = {
    id: "live",
    created_at: ago(900),
    last_sign_in_at: ago(880),
    updated_at: ago(880),
  };
  const result = plan([ancient], new Map([["live", "profiles"]]));
  assert.deepEqual(result.deletable, []);
  assert.equal(result.kept.has_profiles, 1);
});

Deno.test("any one leftover row keeps the account", () => {
  // profiles is the guarantee; the other three are the belt. Each on its own
  // is proof this is not a finished deletion.
  for (const table of OWNED_TABLES) {
    const result = plan([orphan("u")], new Map([["u", table]]));
    assert.deepEqual(result.deletable, [], `${table} did not protect the row`);
    assert.equal(result.kept[`has_${table}`], 1);
  }
});

Deno.test("a young orphan is kept until the age window closes", () => {
  assert.equal(timeKeepReason(orphan("u", 29), NOW, 30), "too_young");
  assert.equal(timeKeepReason(orphan("u", 31), NOW, 30), null);
  // Exactly at the boundary is still too young: the one moment the answer is
  // ambiguous, the tie goes to the account.
  assert.equal(timeKeepReason(orphan("u", 30), NOW, 30), "too_young");
  assert.equal(
    timeKeepReason(
      { id: "u", created_at: ago(400), last_sign_in_at: ago(30) },
      NOW,
      30,
    ),
    "signed_in_recently",
    "the sign-in boundary is inclusive too",
  );
});

Deno.test("recent activity keeps the account even with nothing left of it", () => {
  const signedIn: AuthUserLike = {
    id: "u",
    created_at: ago(400),
    last_sign_in_at: ago(2),
  };
  assert.equal(timeKeepReason(signedIn, NOW, 30), "signed_in_recently");

  // updated_at moves on a token refresh or an email change; either is somebody
  // still using this account.
  const touched: AuthUserLike = {
    id: "u",
    created_at: ago(400),
    last_sign_in_at: ago(400),
    updated_at: ago(3),
  };
  assert.equal(timeKeepReason(touched, NOW, 30), "touched_recently");
});

Deno.test("a timestamp we cannot read is a keep, never a sweep", () => {
  assert.equal(
    timeKeepReason({ id: "u" }, NOW, 30),
    "unreadable_created_at",
    "no created_at at all",
  );
  assert.equal(
    timeKeepReason({ id: "u", created_at: "last tuesday" }, NOW, 30),
    "unreadable_created_at",
  );
  assert.equal(
    timeKeepReason(
      { id: "u", created_at: ago(400), last_sign_in_at: "nonsense" },
      NOW,
      30,
    ),
    "signed_in_recently",
    "an unparseable sign-in reads as just now",
  );
  assert.equal(
    timeKeepReason(
      { id: "u", created_at: ago(400), updated_at: "nonsense" },
      NOW,
      30,
    ),
    "touched_recently",
  );
});

Deno.test("a null last_sign_in_at is normal, not suspicious", () => {
  // Signing up and never coming back is exactly what a deleted account looks
  // like. Absent must not be confused with unreadable.
  assert.equal(
    timeKeepReason(
      {
        id: "u",
        created_at: ago(400),
        last_sign_in_at: null,
        updated_at: null,
      },
      NOW,
      30,
    ),
    null,
  );
});

// ------------------------------------------------------------- the delete set

Deno.test("the CI shape — aged, signed out, nothing owned — is what gets swept", () => {
  const result = plan([orphan("ci-a"), orphan("ci-b"), orphan("ci-c")]);
  assert.deepEqual(result.deletable, ["ci-a", "ci-b", "ci-c"]);
  assert.equal(result.scanned, 3);
  assert.equal(result.withheldByCap, 0);
});

Deno.test("every keep reason is tallied, and the tally starts at zero", () => {
  const empty = plan([]);
  for (const reason of KEEP_REASONS) {
    assert.equal(empty.kept[reason], 0, `${reason} missing from the tally`);
  }

  const mixed = plan(
    [
      orphan("gone"),
      orphan("young", 3),
      { id: "live", created_at: ago(90), last_sign_in_at: null },
    ],
    new Map([["live", "posts"]]),
  );
  assert.deepEqual(mixed.deletable, ["gone"]);
  assert.equal(mixed.kept.too_young, 1);
  assert.equal(mixed.kept.has_posts, 1);
  assert.equal(mixed.scanned, 3);
});

Deno.test("maxDeletes bounds a run; the rest come back tomorrow", () => {
  const users = [orphan("a"), orphan("b"), orphan("c"), orphan("d")];
  const result = plan(users, new Map(), { maxDeletes: 2 });
  assert.deepEqual(result.deletable, ["a", "b"]);
  assert.equal(result.withheldByCap, 2);

  // maxDeletes 0 is a report even when `apply` is set — nothing to delete.
  assert.deepEqual(plan(users, new Map(), { maxDeletes: 0 }).deletable, []);
});

// ------------------------------------------------------------------ the knobs

Deno.test("report is the default: only a literal true arms the sweep", () => {
  assert.equal(sweepParams({}).apply, false);
  assert.equal(sweepParams(undefined).apply, false);
  assert.equal(sweepParams("apply").apply, false);
  assert.equal(sweepParams([true]).apply, false);
  assert.equal(sweepParams({ apply: 1 }).apply, false);
  assert.equal(sweepParams({ apply: "yes" }).apply, false);
  assert.equal(sweepParams({ apply: "TRUE" }).apply, false);
  assert.equal(sweepParams({ apply: true }).apply, true);
  assert.equal(sweepParams({ apply: "true" }).apply, true, "curl-friendly");
});

Deno.test("the numbers are clamped towards the safe end", () => {
  assert.equal(sweepParams({}).minAgeDays, SWEEP_DEFAULT_MIN_AGE_DAYS);
  assert.equal(sweepParams({}).maxDeletes, SWEEP_DEFAULT_MAX_DELETES);
  // A cron config asking for "everything older than a day" gets the floor.
  assert.equal(
    sweepParams({ minAgeDays: 1 }).minAgeDays,
    SWEEP_MIN_AGE_FLOOR_DAYS,
  );
  assert.equal(
    sweepParams({ minAgeDays: -900 }).minAgeDays,
    SWEEP_MIN_AGE_FLOOR_DAYS,
  );
  assert.equal(
    sweepParams({ minAgeDays: 1e9 }).minAgeDays,
    SWEEP_MAX_MIN_AGE_DAYS,
  );
  assert.equal(sweepParams({ minAgeDays: "45" }).minAgeDays, 45);
  assert.equal(sweepParams({ maxDeletes: -5 }).maxDeletes, 0);
  assert.equal(
    sweepParams({ maxDeletes: 99999 }).maxDeletes,
    SWEEP_MAX_DELETES_CEILING,
  );
});

Deno.test("a non-numeric knob is a 400, not a silent default", () => {
  assert.throws(
    () => sweepParams({ minAgeDays: "thirty" }),
    (err: unknown) => {
      assert.ok(err instanceof HttpError);
      assert.equal(err.status, 400);
      assert.equal(err.code, "invalid_minAgeDays");
      return true;
    },
  );
  assert.throws(() => sweepParams({ maxDeletes: {} }), HttpError);
});

// --------------------------------------------------------- the owner paging

Deno.test("collectOwners asks again after a full page", async () => {
  // One member with more posts than the page holds. The naive single-query
  // version reports everyone else as owning nothing — which is the one bug in
  // this feature that deletes a live account.
  const ids = ["loud", "quiet", "alsoquiet"];
  const rows: Record<string, string[]> = {
    loud: ["loud", "loud"],
    quiet: ["quiet"],
    alsoquiet: [],
  };
  const seen: string[][] = [];
  const owners = await collectOwners(ids, (batch, limit) => {
    seen.push([...batch]);
    const page: string[] = [];
    for (const id of batch) {
      for (const row of rows[id] ?? []) {
        if (page.length < limit) page.push(row);
      }
    }
    return Promise.resolve(page);
  }, 2);

  assert.deepEqual([...owners].sort(), ["loud", "quiet"]);
  assert.equal(seen.length, 2, "a full page must be followed by another ask");
  assert.deepEqual(seen[1], ["quiet", "alsoquiet"], "the loud id was dropped");
});

Deno.test("collectOwners stops on a short page and skips an empty ask", async () => {
  let calls = 0;
  const owners = await collectOwners(["a", "b"], (_batch, _limit) => {
    calls += 1;
    return Promise.resolve(["a"]);
  }, 200);
  assert.deepEqual([...owners], ["a"]);
  assert.equal(calls, 1);

  const none = await collectOwners([], () => {
    throw new Error("must not ask about an empty set");
  });
  assert.equal(none.size, 0);
});

Deno.test("collectOwners fails closed rather than vouching for a set it cannot", async () => {
  // A fetcher that keeps returning a full page of ids nobody asked about would
  // otherwise spin forever, or worse, return early with a set that is missing
  // real owners.
  await assert.rejects(
    () => collectOwners(["a", "b"], () => Promise.resolve(["zz", "yy"]), 2),
    /did not converge/,
  );
});

Deno.test("the owner columns match the schema", () => {
  // profiles keys the account on `id`; everything else on `user_id`. Getting
  // this wrong is a PostgREST error, not a silent widening — but it is still
  // cheaper to catch here.
  assert.deepEqual(OWNED_TABLE_COLUMN.profiles, "id");
  for (const table of OWNED_TABLES.filter((t) => t !== "profiles")) {
    assert.equal(OWNED_TABLE_COLUMN[table], "user_id");
  }
});
