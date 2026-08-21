# SalahBuddy backend (Supabase)

The server side of **SPEC-V4** — real circles instead of `BuddySimulator`.

One rule governs everything here: **the server stores facts, never scores.**
A post is "user X prayed Y on day Z at tier T". Every client re-derives the
leaderboard from those facts with `GameEngine`, exactly as it does today for
simulated buddies. That keeps `GameEngine` the single source of scoring truth
(CLAUDE.md), keeps the backend dumb enough to be fully testable, and means a
scoring change ships in an app update with no migration.

The iOS app still runs the simulator by default. This backend is Phase A of the
rollout in SPEC-V4 §10: schema, RLS, functions, CI. Nothing in the app depends
on it being up.

---

## What lives where

```
backend/
  supabase/
    config.toml                     # CLI project config. No refs, URLs or keys — ever.
    seed.sql                        # STAGING-ONLY demo circle, idempotent, hand-written uuids
    migrations/
      20260821000100_init.sql       # enums, tables, constraints, indexes, circle_max_members()
      20260821000200_rls.sql        # enable RLS + every policy + grants (never to `anon`)
      20260821000300_triggers.sql   # updated_at, the cap-8 trigger, profile auto-create
      20260821000400_rpcs.sql       # create/join/leave/rename circle, nudges, retention, delete_account
      20260821000500_storage.sql    # private `prayer-photos` bucket + path-scoped object policies
      20260821000600_realtime.sql   # publication membership + replica identity for live updates
    functions/
      _shared/                      # apns.ts, auth.ts, db.ts, http.ts, messages.ts, util.ts, validate.ts
      notify/index.ts               # post / join / nudge push fan-out (APNs, signed in-function)
      retention/index.ts            # the ~30-day photo sweep
  tests/
    shim/00_supabase_shim.sql       # fakes auth.*/storage.*/the API roles on vanilla Postgres
    sql/01..16_*.sql                # assertion tests — RLS, cap-8, privacy, constraints
    run_sql_tests.sh                # scratch DB -> shim -> migrations -> assertions
    deno/*_test.ts                  # unit tests for the function helpers (offline, no permissions)
```

Migrations are named `<timestamp>_name.sql` because `supabase db push` applies
them in lexical order — the same order `run_sql_tests.sh` uses, so local runs
and the real project can never diverge on ordering.

### The pieces worth knowing before you edit anything

- **`public.current_circle_id()`** is the read predicate for almost every
  policy. It is `SECURITY DEFINER` on purpose: a plain function would re-enter
  `circle_members`' own SELECT policy and recurse.
- **Enum labels match the Swift `rawValue`s exactly** — `log_tier` is
  `'onTime','prayed','lastCall','closeCall','qada'`, camelCase and quoted. If
  you rename a case in `Models.swift`, this is a migration, not a refactor.
- **`day_key` is the client's schedule day**, `yyyy-MM-dd`, and the
  Isha-after-midnight rule travels with the post. The server never re-derives
  it (it does not know the member's timezone or prayer windows, and should not).
- **`logged_at` is UTC; `day_key`/`week_key` are client-local strings.** v4
  assumes same-city circles; cross-timezone circles render each member by their
  own `day_key` and that is an accepted soft spot (SPEC-V4 §7).
- **Automatic RLS is OFF on this project**, so every table needs an explicit
  `enable row level security`. Test 12 walks `pg_class` and fails the build if
  one is missed — that assertion exists because the failure mode is silent.

---

## Running the tests locally

**There is no Docker in the cloud sandbox, so `supabase start` is not an
option**, and `*.supabase.co` is blocked by egress policy. Everything below
runs against a plain Postgres 16 with the shim applied. That is not a
downgrade: the shim gives the migrations a real `auth.users`, real
`auth.uid()`/`auth.jwt()` claim helpers, real `anon`/`authenticated`/
`service_role` roles and a minimal `storage` schema, so the policies under test
are the ones that ship.

### SQL suite

```bash
# The sandbox's Postgres (socket mode, trust auth, superuser postgres):
backend/tests/run_sql_tests.sh

# Any other cluster — full conninfo:
PGURI=postgresql://postgres@localhost:5432/postgres PGPASSWORD=postgres \
  backend/tests/run_sql_tests.sh

# ...or the usual libpq variables (defaults shown: -h /tmp -p 5433 -U postgres):
PGHOST=/tmp PGPORT=5433 PGUSER=postgres backend/tests/run_sql_tests.sh
```

It creates a throwaway database (`salahbuddy_test_$$`, dropped on exit), applies
the shim, then every migration, then every `tests/sql/*.sql`, printing
`PASS`/`FAIL` per file and exiting non-zero if any failed. Passwords stay in
`PGPASSWORD` rather than the URI so nothing secret can end up in an echoed
conninfo string. Set `SCRATCH_DB` to keep a fixed name if you want to poke at
the database afterwards (it is still dropped at exit — comment out the trap).

Tests impersonate users with `set local role authenticated` +
`set local request.jwt.claims`, each file in its own transaction, so they leave
no residue and can run in any order.

### Edge functions

```bash
cd backend
deno check supabase/functions/_shared/*.ts supabase/functions/*/index.ts tests/deno/*.ts
deno test tests/deno/
```

No permission flags: the helpers are pure and every test injects its own
`fetch`, so APNs signing and payload building are covered with zero network. If
a test suddenly needs `--allow-net`, it stopped being a unit test.

Only `npm:` and `node:` specifiers work in this sandbox — `jsr:`, `deno.land`
and `esm.sh` are blocked. `@supabase/supabase-js` is therefore imported as
`npm:@supabase/supabase-js@2.58.0`, which the Supabase edge runtime supports.

---

## How CI deploys

`.github/workflows/backend.yml`, path-filtered to `backend/**`. Three jobs:

| job | runs when | does |
|---|---|---|
| `test` | every push to `staging`, `production`, `dev/**` | Postgres 16 service → `run_sql_tests.sh`, then `deno check` + `deno test` |
| `deploy-staging` | `test` passed **and** ref is `staging` | `supabase link` → `db push` → `functions deploy --use-api` |
| `smoke-staging` | `deploy-staging` actually deployed | curl-level proofs against staging with the publishable key only |

Pushes to `dev/**` stop after `test` — iterate freely, merge to `staging` when
you want the real project updated. Pushes to `production` also stop after
`test` (see the TODO below). `concurrency` deliberately does **not** cancel in
progress: killing a run mid `db push` can leave the remote migration history
half-applied.

### Credentials CI expects

Nothing here is stored in the repo. Names only:

| name | kind | used by |
|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | secret | `deploy-staging` (Supabase account token) |
| `SUPABASE_STAGING_PROJECT_REF` | secret | `deploy-staging` |
| `SUPABASE_STAGING_DB_PASSWORD` | secret | `deploy-staging` |
| `SUPABASE_STAGING_URL` | **variable** (secret also accepted) | `smoke-staging` |
| `SUPABASE_STAGING_PUBLISHABLE_KEY` | **variable** (secret also accepted) | `smoke-staging` |
| `SUPABASE_STAGING_AUTH_OPTIONAL` | variable, optional | set to `true` only if staging deliberately has email signups off |

The URL and publishable key are *variables* rather than secrets on purpose:
neither is confidential (both ship inside the iOS binary), and variables stay
readable in the Actions UI, which is what makes a smoke failure debuggable. The
workflow masks them anyway before the first request, because this repo is
public and a project ref in a log is still noise nobody needs.

Every job **skips with an explanatory notice** when its credentials are absent —
a fork or a fresh clone gets a green, self-explaining run instead of red Xs.

### What the smoke test proves

It is the Phase A exit criterion ("staging accepts a signed-in user via a
curl-level test", SPEC-V4 §10), re-run on every deploy:

1. The publishable key **on its own reads nothing** — `posts`, `profiles`,
   `circles`, `circle_members`, `excused_days` each denied or empty, both with
   `apikey` alone and with an anon bearer. RLS, not key custody, is the
   security boundary; this is the assertion that says so out loud.
2. Three throwaway `@example.com` users sign up and sign in for real tokens.
3. User A's `create_circle` returns a circle and a 6-char invite code from the
   unambiguous alphabet (the code's *value* is masked — a public log should not
   hand out live invites).
4. User B joins with that code and sees a 2-person roster.
5. User C creates an unrelated circle and posts into it; **user B cannot see
   that post**, sees an empty feed, and sees exactly one circle — their own.

Every assertion prints `PASS`/`FAIL`/`SKIP` and lands in the job summary.
Tokens, passwords and invite codes are masked; the run ends by calling
`delete_account()` for each throwaway user. If the project cannot mint a user
(email provider off, or "Confirm email" on — a CI user can never click a link),
the job says exactly which dashboard toggle to flip and **fails**, rather than
reporting proof 1's passes as success. A green tick that proved nothing is the
one outcome this job must never produce.

### Manual deploy, when you need it

```bash
cd backend
export SUPABASE_ACCESS_TOKEN=...          # never write these into a file in this repo
export SUPABASE_DB_PASSWORD=...
supabase link --project-ref <ref>
supabase db push --linked
supabase functions deploy --use-api
```

Function runtime secrets (`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
`APNS_BUNDLE_ID`) are set out of band with `supabase secrets set` — they are
not in CI, and `apnsConfigured()` makes every send path log-and-skip when they
are missing, so an unconfigured project still works, just silently.
`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` are injected by the platform; never
add them to the repo.

`supabase link` writes `backend/supabase/.temp/`, which contains the linked
project ref. **Do not commit it** (see the TODO below).

Free-tier note: Supabase pauses idle projects after ~a week. If a deploy fails
with a connection error after a quiet stretch, unpause the project in the
dashboard first.

---

## Cap 8 means eight people, total

A v4 circle holds **8 members in total, including you** — not 8 friends plus
you. The simulator's `maxFriends = 8` counts *friends* excluding you, so a demo
circle looks like 9 faces and a real one looks like 8. That difference is
deliberate and load-bearing for anyone comparing the two side by side.

The number lives in exactly one place, `public.circle_max_members()` (immutable,
returns 8), so SQL, tests and any future client check agree by construction.

Enforcement is two mechanisms, not one:

- **One circle per user** is `unique (user_id)` on `circle_members`. Not a
  trigger — a constraint, so it holds under any concurrency.
- **The ≤8 cap** is a `BEFORE INSERT` trigger that first takes
  `pg_advisory_xact_lock(hashtext(circle_id))` and then counts. Without the
  lock, two simultaneous joins both see 7 and both succeed; with it, the ninth
  member gets `SQLSTATE SB409`. Test 01 asserts the 8th succeeds and the 9th
  does not.

`join_circle` surfaces failures as SQLSTATEs the client can branch on:
`SB404` unknown code · `SB409` circle full · `SB410` already in a circle ·
`SB401` not signed in.

---

## Privacy invariants

These are product promises expressed as schema. Treat them as tests, not
preferences.

- **`excused_days` has no `reason` column, and never will.** The circle sees a
  gentle "resting" flag; *why* someone is excused never leaves their device
  (SPEC-V4 §3). Test 08 fails the build if a `reason`/`note`/`comment`/`detail`
  column ever appears there, and pins the whole column list besides — a guard
  against the well-meaning migration that "just adds a note field".
- **Recovery XP is an opaque weekly total.** `recovery_weeks` stores
  `(user_id, week_key, xp)` and nothing about *what* was done. Dhikr counts and
  good-deed choices stay local. The scoreboard stays fair for anyone on a break
  without narrating their life to the group.
- **Nothing is world-readable.** No table grants anything to `anon`. Every
  read predicate is "the row's circle is *my* circle", every write predicate
  adds "and the row is mine". `service_role` bypasses RLS and therefore never
  touches a client; only the edge functions hold it, injected by the platform.
- **Photos are private objects in a private bucket**, keyed
  `<circle_id>/<user_id>/<uuid>.jpg`. Folder 1 is the read scope, folder 2 is
  the owner — which is what makes the storage policies one-liners. 5 MiB cap,
  `image/jpeg` only.
- **Nudges are rate-limited by their primary key**, not by a counter:
  `(sender_id, recipient_id, day_key, prayer)`. A second nudge in the same
  window is not an error, it returns `false` — the caller gets
  `{sent:false, reason:"rate_limited"}` and nobody's phone buzzes twice.
- **The developer time-travel offset is forced to zero while a real circle is
  active** (client-side, SPEC-V4 §3). Posting fictional timestamps to real
  friends would break the very thing time travel exists to test.

---

## Retention

Photos are the only heavy, personal thing here, so they age out.

`purge_expired_photo_rows(p_days int default 30)` (SECURITY DEFINER,
`service_role` only):

1. nulls `posts.photo_path` for posts older than `p_days` and **returns the
   paths it just detached**,
2. deletes `nudges` older than 30 days — they are rate-limit tokens, litter
   once the window is gone,
3. deletes `excused_days` / `recovery_weeks` whose owner is no longer in any
   circle (left or deleted their account, so nobody is allowed to read them).

It ages off `created_at`, the server's own clock — never `logged_at`, which is
client-supplied and therefore not a fact about when we stored anything.

The `retention` edge function orchestrates it: `claim_retention_run()` first
(a single-row lease, so two overlapping cron ticks cannot both purge and a
signed-in developer cannot hammer it), then the SQL, then
`storage.remove(paths)` in chunks of 100. **Rows first, objects second** — a
crash mid-delete leaves orphaned bytes (harmless, swept next run) rather than a
post pointing at a photo that no longer exists.

Leaving a circle keeps your posts (the circle's week stays coherent);
`delete_account()` purges everything you own immediately.

---

## TODO before production

- [ ] **No production project exists.** The free tier caps the account at two
      active projects and both slots are taken, so
      `SUPABASE_PRODUCTION_PROJECT_REF` / `SUPABASE_PRODUCTION_DB_PASSWORD`
      do not exist (XCODE-CLOUD.md, "Current state"). `backend.yml` therefore
      has no production deploy job — wiring one up is a copy of
      `deploy-staging` with the ref check and secret names swapped, and the
      smoke job must stay pointed at staging (it creates users and posts rows).
- [ ] **Add `backend/supabase/.temp/` to `.gitignore`.** The Supabase CLI
      writes the linked project ref there; on a public repo that should never
      be committed by accident.
- [ ] **Schedule `retention`.** Nothing calls it yet. Options: `pg_cron` +
      `pg_net` on the project (neither is available in the sandbox, so it must
      be configured against the real database), or an external scheduler
      POSTing with the service-role key. The lease makes over-calling safe.
- [ ] **Sweep orphaned `auth.users` rows.** `delete_account()` purges every
      row a user owns but cannot delete their `auth.users` row (that needs
      `service_role`); the app signs out immediately after. An admin sweep
      still has to remove the shells — including the throwaway CI users, and
      the circles they created, which linger on staging.
- [ ] **APNs secrets on the real project** (`supabase secrets set APNS_*`).
      Until then every push path logs and skips, by design.
- [ ] **UGC report action** — App Store guideline 1.2 needs a report control on
      buddy photos before public release (SPEC-V4 §4). Leaving is the block
      mechanism; the report side needs a server home.
- [ ] **Cross-timezone circles.** Accepted soft spot today. If circles stop
      being same-city, `day_key` has to grow a timezone story.
