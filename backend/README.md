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
      20260821000100_init.sql       # enums, tables, constraints, indexes, the cap/limit constants
      20260821000200_rls.sql        # enable RLS + every policy + COLUMN-SCOPED grants (never `anon`)
      20260821000300_triggers.sql   # updated_at, cap-8, profile auto-create, photo tombstones,
                                    #   departures, the device cap, frozen created_at
      20260821000400_rpcs.sql       # create/join/leave/rename circle, nudges, retention, delete_account
      20260821000500_storage.sql    # private `prayer-photos` bucket + path-scoped object policies
      20260821000600_realtime.sql   # what is published (and what deliberately is not)
      20260821000700_reports.sql    # UGC reports — insert-only for the reporter, read by nobody else
      20260821000800_reports_subject.sql  # a report keeps its own copy of WHO and WHERE (undo-proof)
      20260821000900_register_device.sql  # claim an APNs token that changed hands on one phone
      20260822000100_circle_cap_12.sql    # the circle cap moves from 8 to 12
      20260822000200_post_utc_offset.sql  # record the poster's zone on every post
      20260822000300_post_identity_offset.sql # ...and put it in the posts unique key
      20260822000400_post_zone_wildcard.sql   # a NULL offset is a wildcard, not a third zone
      20260822000500_device_utc_offset.sql    # the RECIPIENT's zone, so push can skip a stale day
    functions/
      _shared/                      # apns.ts, auth.ts, db.ts, http.ts, messages.ts, util.ts,
                                    #   validate.ts, zones.ts
      notify/index.ts               # post / join / nudge push fan-out (APNs, signed in-function)
      retention/index.ts            # the ~30-day photo sweep
  tests/
    shim/00_supabase_shim.sql       # fakes auth.*/storage.*/the API roles on vanilla Postgres
    sql/01..29_*.sql                # assertion tests — RLS, caps, privacy, constraints
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
- **Grants are column-scoped wherever a table has a column the client must not
  write.** A policy answers "which rows"; only the grant answers "which
  columns". `posts.created_at` is the retention clock, so a table-wide UPDATE
  lets a client re-date a row to 2126 and its photo never expires;
  `circles.code` is the invite, so a table-wide UPDATE lets any member kill
  every outstanding invite (or set the code to `''` and capture anyone whose
  join field was blank). Test 12 pins the column matrix in both directions.
- **The keys carry `circle_id`.** `posts` is unique on
  `(user_id, circle_id, day_key, prayer, utc_offset)`, and `excused_days` /
  `recovery_weeks` key on `(user_id, circle_id, …)`. Your rows outlive your
  membership (§2), so a key without the circle makes the join-backfill of your
  current week collide with the rows still sitting in the circle you just left.
- **...and `posts` carries `utc_offset`, NULLS NOT DISTINCT** (migration
  `20260822000300`). A long-haul flight makes two genuinely different prayers
  share one `day_key`, so the zone is part of the row's identity; `nulls not
  distinct` keeps pre-`20260822000200` rows, which have no offset, deduping
  against each other. On real offsets this rule is deliberately LOOSER than the
  client's, which folds offsets within 3h together so a DST hour never splits a
  prayer — do not "tighten" it to match. Test 27 pins both halves.
- **A NULL `utc_offset` is a WILDCARD, and that needs a trigger** (migration
  `20260822000400`, `posts_zone_wildcard`). `nulls not distinct` makes NULL
  equal to NULL and to nothing else, which leaves one pair the index cannot
  see: a zoneless legacy row beside a zoned one. That is one prayer written
  twice — the v4 rollout produces it by itself, from one device on an old build
  and one on the new — and it scores that prayer twice on every circle-mate's
  leaderboard, permanently, because no later upsert ever conflicts with either
  row. The trigger refuses the pair with **23505**, so the client's existing
  slot-repair path (`SupabaseCircleTransport.upsertPost` →
  `updatePostSlot`, scoped `utc_offset = n OR utc_offset is null`) lands on the
  row that refused the insert. It stays SILENT on the pairs the unique key
  already refuses: `on conflict do nothing` can swallow a constraint violation
  and cannot swallow a trigger's exception, and `seed.sql` runs twice. Test 28.
- **Two tables are the sweep's private bookkeeping** and are granted to nobody:
  `circle_departures` (who left which circle, and when — the purge clock) and
  `photo_tombstones` (Storage paths whose row is gone). The tombstone list is
  precisely the set of paths the storage policy is hiding, so `authenticated`
  reaching it would undo the point; the policy consults
  `photo_is_pending_deletion()` instead.

---

## Running the tests locally

**There is no Docker in the cloud sandbox, so `supabase start` is not an
option**, and `*.supabase.co` is blocked by egress policy. Everything below
runs against a plain Postgres 16 with the shim applied. That is not a
downgrade: the shim gives the migrations a real `auth.users`, real
`auth.uid()`/`auth.jwt()` claim helpers, real `anon`/`authenticated`/
`service_role` roles and a minimal `storage` schema, so the policies under test
are the ones that ship.

The shim also reproduces the one piece of Supabase that is a *trap* rather than
a convenience: the default privileges on `public` that grant every newly created
table and function to `anon`, `authenticated` and `service_role`. A vanilla
Postgres has no such thing, so without them the sandbox would be **more locked
down than production** and test 12's "anon holds nothing" assertion would pass
while describing a database it had never seen. With them in place the migrations
have to revoke for real — which is why `20260821000200_rls.sql` resets both
roles before granting back, verb by verb.

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
the shim, then every migration, then every `tests/sql/*.sql`, and finally
`seed.sql` **twice** — the seed is staging-only and `supabase db push` never
runs it, so nothing else would notice it rotting against a schema change, and
applying it twice is what proves the idempotence it claims. Printing `PASS`/
`FAIL` per file, exiting non-zero if any failed. Passwords stay in `PGPASSWORD`
rather than the URI so nothing secret can end up in an echoed conninfo string.
Set `SCRATCH_DB` to keep a fixed name if you want to poke at the database
afterwards (it is still dropped at exit — comment out the trap).

Tests impersonate users with `set local role authenticated` +
`set local request.jwt.claims`, each file in its own transaction, so they leave
no residue and can run in any order. Each is handed `:migrations_dir` as a psql
variable, so a test can `\i` a real migration file (test 17 re-runs the realtime
one against a half-published publication) instead of pasting a copy of its SQL —
a test that reimplements the migration proves nothing about the migration.

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
The smoke proofs need no configuration: they read the staging URL and publishable key from
`Sources/Core/Sync/SupabaseConfig.swift`, so they exercise the exact values the app ships. Set the
repo variables `SUPABASE_STAGING_URL` / `SUPABASE_STAGING_PUBLISHABLE_KEY` only to point them at a
different project (a fork, a throwaway).
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
curl-level test", SPEC-V4 §10), re-run on every deploy. **First scored 53
passed, 0 failed on `9669ad0` (2026-08-21)** — the criterion is met.

1. The publishable key **on its own reads nothing** — every table carrying a
   grant to `authenticated` (`posts`, `profiles`, `circles`, `circle_members`,
   `excused_days`, `recovery_weeks`, `custom_challenges`, `devices`, `nudges`,
   `reports`) denied or empty, both with `apikey` alone and with an anon
   bearer. RLS, not key custody, is the security boundary; this is the
   assertion that says so out loud. A `404` is scored as a FAILURE, not a
   denial: PostgREST answers `404/PGRST205` for a table missing from the schema
   cache, so treating it as "denied" reports a broken deploy as a row of green
   ticks.

   `PROBE_TABLES` is the list, and it is deliberately the same set SQL test
   12's RLS sweep walks — the earlier hand-picked five left `devices` (APNs
   tokens), `nudges` (who nudged whom) and `reports` (who reported whom)
   unprobed, which are the three whose contents would be worst to leak.
2. Three throwaway users sign up and sign in for real tokens. The address
   domain is `SUPABASE_STAGING_CI_EMAIL_DOMAIN`, defaulting to
   `salahbuddy.app`: Supabase's validator refuses `@example.com` outright.
3. User A's `create_circle` returns a circle and a 6-char invite code from the
   unambiguous alphabet (the code's *value* is masked — a public log should not
   hand out live invites).
4. User B joins with that code and sees a 2-person roster.
5. User C creates an unrelated circle, posts into it and marks a resting day;
   **user B cannot see that post**, sees an empty feed, and sees exactly one
   circle — their own.
6. The proof-1 reads are repeated **while those rows exist**. Proof 1 runs
   before anything has been created and the cleanup trap deletes it all again,
   so on its own it reads empty tables — which passes identically with RLS
   switched off. Proof 6 is the assertion; proof 1 is the smoke check.

Every assertion prints `PASS`/`FAIL`/`SKIP` and lands in the job summary.
Tokens, passwords and invite codes are masked; the run ends by calling
`delete_account()` for each throwaway user. If the project cannot mint a user
(email provider off, or "Confirm email" on — a CI user can never click a link),
the job says exactly which dashboard toggle to flip and **fails**, rather than
reporting proof 1's passes as success. A green tick that proved nothing is the
one outcome this job must never produce.

#### Where "Confirm email" actually lives (2026-08-21)

Enabled on staging so the proofs can run: the **Email** provider is on (it is
by default) and **Confirm email** is **off**. Staging holds no real data. The
proofs have now passed (53/53), but leave it off: they re-run on every deploy
and turning it back on breaks them again.

**The setting is not where you would look for it.** "Confirm email" is NOT
inside the Email provider's dialog — it is a project-level setting in the
**User Signups** block at the top of *Authentication → Sign In / Providers*,
and it has its **own separate "Save changes" button**. Toggling it inside the
provider dialog and saving there does nothing, which looks exactly like the
setting not taking effect.

Recorded because the failure it causes is indistinguishable from the provider
being off, and the next person to hit it will otherwise spend the same twenty
minutes in the wrong dialog.

The **Google** provider's *Client IDs* field already contains the iOS client
id (`923951498597-…apps.googleusercontent.com`), so nothing is needed there.
CI cannot check that one — a wrong value there surfaces only when somebody
taps "Sign in with Google" on a real phone.

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

## Cap 12 means twelve people, total

A v4 circle holds **12 members in total, including you** — not 12 friends plus
you. The simulator's `maxFriends = 11` counts *friends* excluding you, so both
modes seat twelve.

It was 8 through the beta, and the demo/real pair showed 9 faces against 8. That
was not a decision anybody made: the 8 came from a v2/v3 comment about the
SIMULATED circle ("sharing five photos a day is an intimate thing; past ~8 it
stops feeling like a circle"), real circles inherited the number without
re-deriving it, and the two modes then counted it differently. 12 was picked on
purpose — it seats a family or a masjid friend group, and it stays inside what
the sync path was built for. The reconciling pull reads the whole 35-day window
for every member and every device re-runs `GameEngine` over all of it, so the
payload is ~1,400 posts at 8 seats and ~2,100 at 12. That is why it is 12 and
not 50.

The number lives in exactly one place, `public.circle_max_members()` (immutable,
returns 12), so SQL, tests and any future client check agree by construction.
`CircleSeamTests` asserts the client's two constants match it and each other.

Enforcement is two mechanisms, not one:

- **One circle per user** is `unique (user_id)` on `circle_members`. Not a
  trigger — a constraint, so it holds under any concurrency.
- **The ≤12 cap** is a `BEFORE INSERT` trigger that first takes
  `pg_advisory_xact_lock(hashtext(circle_id))` and then counts. Without the
  lock, two simultaneous joins both see 11 and both succeed; with it, the
  thirteenth member gets `SQLSTATE SB409`. Test 01 asserts the 12th succeeds and
  the 13th does not, deriving both from `circle_max_members()` so it follows the
  cap instead of failing for the wrong reason when it next moves.

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
  `(user_id, circle_id, week_key, xp)` and nothing about *what* was done. Dhikr counts and
  good-deed choices stay local. The scoreboard stays fair for anyone on a break
  without narrating their life to the group.
- **The timestamps on those two rows are not readable by the circle either.**
  SELECT on `excused_days` and `recovery_weeks` is column-scoped, because a bare
  flag stops being bare when a circle-mate can see `created_at` — the minute
  somebody's break started — and an opaque total stops being opaque when
  `updated_at` advances on every dhikr tap and every good deed. The client
  already declines to mirror both (`RemoteModels.swift` says so in as many
  words), but "the honest client does not ask" is not a boundary; the grant is.
  Test 19 reads them as a circle-mate and expects `insufficient_privilege`,
  including through a lazy `select *`.
- **Nothing is world-readable.** `anon` is explicitly *revoked* from every table
  and RPC — not merely left ungranted, because Supabase's default privileges on
  `public` hand new objects to `anon` before a migration says a word. Every read
  predicate is "the row's circle is *my* circle", every write predicate adds
  "and the row is mine". `service_role` bypasses RLS and therefore never touches
  a client; only the edge functions hold it, injected by the platform.
  `authenticated` is reset the same way and granted back verb by verb, so the
  privilege matrix in `20260821000200_rls.sql` is the one that deploys — test 12
  pins it in both directions (an extra verb fails; a missing one fails too).
- **Photos are private objects in a private bucket**, keyed
  `<circle_id>/<user_id>/<uuid>.jpg`. Folder 1 is the read scope, folder 2 is
  the owner — which is what makes the storage policies one-liners. 5 MiB cap,
  `image/jpeg` only.
- **Nudges are rate-limited by their primary key** —
  `(sender_id, recipient_id, day_key, prayer)` — *plus* two clock-based bounds,
  because the key alone is only a limit against an honest client. `day_key` is
  the caller's schedule day, so an unbounded one is ~18 million fresh primary
  keys against one circle-mate (3.65M days × 5 prayers), each a real push.
  `record_nudge()` therefore rejects a `day_key` more than a day either side of
  `now()` (±1 day covers every real timezone offset) and caps a sender at
  `nudge_hourly_cap()` per hour. A second nudge in the same window is not an
  error, it returns `false` — the caller gets
  `{sent:false, reason:"rate_limited"}` and nobody's phone buzzes twice.
- **A phone's `devices` row follows its APNs token, and only `register_device()`
  can move it.** `apns_token` is the primary key and one install keeps the same
  token for life, so when a second person signs in on that phone the row has to
  change hands. A client `upsert(on_conflict=apns_token)` cannot do it:
  ON CONFLICT DO UPDATE tests the UPDATE policy's USING clause against the
  EXISTING row, and `devices_all` is `user_id = auth.uid()`, so the previous
  account's row is a `42501` the new account can neither update nor delete. It
  would simply stay — the old circle pushing a friend's name and prayer to a
  phone somebody else is now holding. The RPC is SECURITY DEFINER and deletes
  any row carrying that token before inserting the caller's; deleting by token
  alone is safe because a token is an unguessable value APNs issues to one
  install. Test 26 pins both halves.
- **A post's push is scoped to the day it is about, and "unknown" is never
  silence** (migration `20260822000500`, `functions/_shared/zones.ts`, test 29
  + `tests/deno/zones_test.ts`). `notify` used to fan "📸 X posted first for
  Fajr" out to every member regardless of where they were standing: a 5am Fajr
  in Mumbai woke a friend in Seattle at 4:30pm, twelve hours after their own
  Fajr. `devices.utc_offset` is the missing half of `posts.utc_offset` — with
  both, the function can compute each recipient's local day and drop the ones
  the post has already gone stale for. Four things about it are load-bearing:
  - **the window is anchored on the POSTER**, spanning `day_key` to the
    poster's own current local day. That is what guarantees nobody in the
    poster's own zone is ever filtered, and it is what keeps an Isha logged
    after midnight — which carries YESTERDAY's `day_key` — reaching the same
    city. A bare `recipient_day == day_key` would have silenced that case for
    everyone, in one line, with no timezone involved at all.
  - **the recipient gets the same after-midnight allowance**, or the poster's
    half of it is a bug rather than a fix. `day_key` is a SCHEDULE day and
    `localDayKey` is a CALENDAR day, and between midnight and dawn those are
    two different dates: with the poster in London at 23:30 the window is a
    single date, so a circle-mate one hour east reading 00:30 — the same clock
    face that keeps a same-city recipient in — was dropped for standing on
    tomorrow's date. Seattle/Denver and UK/Central Europe lost the "posted
    first for Isha" push that way most nights. `isCurrentForOffset` therefore
    accepts `window.to + 1` while the recipient is before dawn
    (`PRE_DAWN_SECONDS`, a flat four hours — the function has no coordinates
    and so cannot know their real Fajr). It only ever ADDS recipients, so the
    poster-zone invariant is untouched.
  - **NULL is a third answer, not a zone.** The column is nullable forever and
    has no default: every row written before the migration genuinely has no
    offset, and 0 is a real place (London in winter, Reykjavík all year), so a
    `not null default 0` would file every unknown device in Greenwich and mute
    the ones whose day has not turned over. A NULL recipient offset is always
    notified; a post with a NULL `utc_offset` filters nobody at all.
  - **only the post fan-out is filtered.** A nudge is aimed at one named person
    a human just picked out of a grid and never goes through `fanOut`;
    `{kind:"join"}` is not about a day and passes no window.
  `register_device()` gained `p_utc_offset int default null` here, and the
  three-argument function was DROPPED rather than left beside it — two
  overloads differing only by a defaulted trailing parameter make every
  existing call ambiguous. An out-of-range offset is coerced to NULL by the RPC
  rather than raised, because a phone with no `devices` row gets no nudges and
  no join alerts either: a bad clock must cost the filtering, never the
  registration.
- **Push is opt-in and first-only.** §6's friend-activity alert is
  `devices.notify_friend_activity`, which mirrors `AppSettings` and defaults to
  **false**; the fan-out filters on it, because iOS cannot suppress an alert it
  has already been handed. `notify` announces a post only when no earlier post
  exists for that `(circle, day, prayer)` and claims `posts.notified_at` as a
  one-shot lease, so a circle of 12 produces one alert per window rather than 11
  — and the same `postId` can never be re-announced. `{kind:"join"}` claims
  `circle_members.announced_at` the same way.
- **Realtime publishes `posts` and `custom_challenges` — and deliberately not
  `circle_members` or `excused_days`.** Realtime cannot apply RLS to DELETE
  events (there is no row left to test a policy against), so a delete is
  broadcast to every subscriber in the project carrying the row's primary key.
  For those two tables the primary key IS the private fact: un-marking a rest
  day would announce `(user_id, circle_id, day_key)` product-wide, and a
  departure would announce the user→circle graph. **The client re-fetches the
  roster and the resting flags on a `posts` event or on foreground.** For the
  same reason `posts` keeps the DEFAULT (primary-key) replica identity: walrus
  truncates a delete's `old_record` to the primary key whenever RLS is on, so
  `replica identity full` delivers nothing and costs a full old tuple in the
  WAL on every UPDATE. An undo arrives as an opaque `{id}` the client resolves
  against its own mirror.
- **Invite codes are throttled and format-checked.** 32^6 ≈ 1.07e9 codes is a
  keyspace an online guesser walks in an afternoon, and one hit reads a
  stranger's whole circle. `circles.code` has a CHECK for the six-character
  unambiguous alphabet (an empty code used to be legal, which made
  `join_circle('')` land the caller in whichever circle had claimed it),
  `join_circle` rejects a malformed code before it looks anything up, and
  attempts are charged against an hourly budget. That meter is a SEQUENCE, not
  a table, because every failure path here RAISES and a raise rolls back
  whatever a counter just wrote — `nextval`/`setval` are the only writes
  Postgres does not roll back, so they are the only way to remember a failed
  guess. Known trade-off: the budget is project-global, so a determined
  attacker can spend it and make joins fail for an hour. Per-user accounting
  needs a caller that can commit between attempts (an Edge Function) and is a
  Phase D conversation.
- **The developer time-travel offset is forced to zero while a real circle is
  active** (client-side, SPEC-V4 §3). Posting fictional timestamps to real
  friends would break the very thing time travel exists to test.

---

## Retention

Photos are the only heavy, personal thing here, so they age out.

**Every path that can detach a photo records it first.** An AFTER trigger on
`posts` writes `old.photo_path` into `photo_tombstones` on DELETE and on any
change of the column — so undo, `delete_account()`, a replaced photo and the
sweep itself all leave the path behind. Without it the only reference to a
Storage object dies with the row: a deleted account's prayer photos would sit
in the bucket forever, unreachable by any sweep and readable by every remaining
member of the circle. A tombstoned path also stops being readable *immediately*
— the storage SELECT policy consults `photo_is_pending_deletion()` — so §4's
"deletion purges immediately" is true of the read, not just eventually of the
bytes.

`purge_expired_photo_rows(p_days int default 30, p_limit int default 500)`
(SECURITY DEFINER, `service_role` only):

1. nulls `posts.photo_path` for posts older than `p_days` (the trigger
   tombstones each path),
2. purges a departed member's footprint — posts, resting days, recovery total,
   custom challenges — once `departure_grace_days()` (7) has passed since they
   left, which is §2's "until the week ends" without the server ever having to
   derive a week boundary in somebody else's timezone,
3. deletes `nudges` older than 30 days — they are rate-limit tokens, litter
   once the window is gone,
4. deletes ownerless `excused_days` / `recovery_weeks` **scoped to the row's own
   circle** and only after 30 days. Both halves matter: "is this user in *a*
   circle" let a member who moved from A to B keep rendering resting days to
   circle A forever, and no age guard meant a leaver's resting flags vanished
   the instant they left while their posts stayed — turning a gentle "resting"
   into a wall of plain misses for the circle they just left,
5. deletes circles nobody is in any more (they cascade, and an abandoned circle
   otherwise keeps its invite code alive against the code space forever),
6. **returns a bounded batch of pending Storage paths** from `photo_tombstones`.

It ages off `created_at`, the server's own clock — never `logged_at`, which is
client-supplied and therefore not a fact about when we stored anything. That is
only true because `created_at` is not writable: the column-scoped grants keep
`authenticated` off it, and a BEFORE UPDATE trigger pins it against the
service-role client too.

The `retention` edge function orchestrates it: `claim_retention_run()` first (a
single-row lease, so two overlapping cron ticks cannot both purge and a
signed-in developer cannot hammer it), then the SQL, then
`storage.remove(paths)` in chunks of 100 — and then `confirm_photo_deletions()`
for each batch Storage actually accepted. **Confirm-after-delete is what makes
the sweep resumable**: a failed batch, or a run the wall clock kills mid-loop,
leaves those paths on the tombstone list and the next tick picks them up.
Returning the paths from the same statement that erased them (the previous
shape) lost them permanently on any partial failure. `p_limit` bounds a run so
the first sweep after a long gap cannot return an unbounded set and guarantee
the timeout it exists to avoid.

Leaving a circle keeps your posts for the rest of the week (the circle's week
stays coherent) and then purges them; `delete_account()` purges everything you
own immediately, photos included.

---

## Reporting a photo

App Store guideline 1.2 wants a way to flag user-generated content before the
app is public, and SPEC-V4 §4 parks exactly that: a **report** action on any
buddy photo, with **leaving the circle as the block mechanism**. `reports` is
the server half — `20260821000700_reports.sql`.

```
id               uuid    client-generated (like posts.id), default gen_random_uuid()
reporter_id      uuid    -> auth.users     ON DELETE SET NULL
post_id          uuid    -> public.posts   ON DELETE SET NULL
circle_id        uuid    -> public.circles ON DELETE SET NULL
reported_user_id uuid    -> auth.users     ON DELETE SET NULL   (pinned to posts.user_id)
photo_path       text    nullable          (pinned to posts.photo_path)
reason           text    nullable, <= 500 chars
created_at       timestamptz  server-owned
unique (reporter_id, post_id)
```

| role | privileges on `public.reports` |
|---|---|
| `anon` | none — explicitly revoked |
| `authenticated` | `INSERT (id, reporter_id, post_id, circle_id, reported_user_id, photo_path, reason)` — column-scoped, and nothing else |
| `service_role` | `SELECT, INSERT, UPDATE, DELETE` |

**The reporter writes and cannot read.** That asymmetry is the design. A circle
is eight people who know each other, so a readable `reports` table is an
enumeration of *who reported whom*: one `select *` and a member learns that
three of their friends flagged the same photo, or that somebody flagged theirs.
There is no UPDATE or DELETE either — a report is a fact that was filed, not a
message to be edited or withdrawn, and "I can see my own row" is one widened
policy away from "I can see yours". RLS carries a single INSERT policy and no
others, so even a mistakenly widened grant still reads zero rows.

The policy re-derives the subject from the database rather than trusting the
body (the rule the `notify` function follows): the row's `circle_id` must be the
caller's current circle, and `post_id` must name a post that caller can actually
see. Without that, a member could file reports against any uuid at all, or
attribute one to a circle they have left.

**Nothing that gets deleted takes a report with it.** All three foreign keys are
`ON DELETE SET NULL`, and both alternatives are wrong in opposite directions:

- `CASCADE` from `posts` would hand the reported member a retraction button —
  undo is a button in the app, so "report me and I'll tap undo" erases the
  complaint before a human reads it.
- `NO ACTION` (the default) fails the other way: the post could no longer be
  deleted while a report pointed at it, so undo, `delete_account()` and the
  retention sweep would start erroring on precisely the rows a moderator cares
  about. A reported photo would become the one photo nobody can remove — kept
  alive in the bucket by the complaint against it.

`SET NULL` keeps both promises: the delete proceeds untouched and the report
survives it.

**And what survives has to still name somebody.** `SET NULL` on its own only
saved the ROW — `post_id` went null and triage was left with a timestamp, a
reason and nobody to answer for it, so a member could defeat every report
against them by tapping undo. `20260821000800_reports_subject.sql` gives the
report its own copy of the subject: `reported_user_id` and `photo_path`, both
**pinned by the insert policy against the `posts` row itself** rather than taken
on trust from the body. A freely-chosen copy would be a way to name a friend in
a complaint they had nothing to do with; the policy requires
`p.user_id = reports.reported_user_id` and `reports.photo_path = p.photo_path`,
and refuses a null subject outright. Test 25 asserts all of it, and the negative
cases were verified by breaking the migration on purpose (a `CASCADE` fails
"deleting the reported post erased the report", a `NO ACTION` fails the delete
itself, and dropping the pin fails "filed a report that named no member").

### Client contract

- **Plain `insert`, and `returning: .minimal`.** `RETURNING` needs SELECT
  privilege, so a default `return=representation` insert is refused outright,
  whole statement, not just the echo.
- **Treat `23505` (unique violation) as "already reported".** `CircleSync`'s
  existing `isUniqueViolation(error)` is the check. Do **not** reach for
  PostgREST's `on_conflict=reporter_id,post_id`: an `ON CONFLICT` *inference*
  clause needs SELECT on the arbiter columns, and those two columns are exactly
  the pair that would publish who reported whom, so the write-only grant and
  that parameter are mutually exclusive by construction. (Test 25 pins both
  halves — the targeted form is refused, the targetless one is not.)
- **Send the subject with it.** `reported_user_id` is the post's author and
  `photo_path` is the post's path; both are re-derived server-side, so sending
  anything else is a `42501`, and sending nothing is one too.
- **Hide the photo locally the moment the report is filed** (SPEC-V4 §4). The
  server does not hide anything for the reporter; nothing here changes what the
  circle sees.
- **Keep the report queued unless the server actually answered.** A `23505` is
  "already reported" (success); a refusal it uttered — `42501`, a post that is
  gone — is final. Everything else (a 502, a paused project, a body that would
  not decode) is transient and must NOT settle the report: the client gives
  those a bounded number of attempts and charges nothing at all for being
  offline. `PhotoReports.outcome(for:)` is that table.

### Two things this deliberately does not do

- **Triage has a deadline.** The reported photo ages out of Storage on the
  normal ~30-day retention clock, so a report older than that points at a post
  whose `photo_path` is already null. The evidence window is the retention
  window, by design — reports are read on a human cadence well inside it.
- **`delete_account()` does not touch `reports`.** Deleting your account must
  not retract a complaint you filed about someone else's photo; the FK
  anonymises it instead, when the orphaned `auth.users` shell is finally swept
  (see the TODO below). If that sweep stays unbuilt and the lingering
  `reporter_id` becomes uncomfortable, the one-line fix is
  `update public.reports set reporter_id = null where reporter_id = v_uid`
  inside the RPC — not a delete.

---

## TODO before production

- [ ] **No production project exists.** The free tier caps the account at two
      active projects and both slots are taken, so
      `SUPABASE_PRODUCTION_PROJECT_REF` / `SUPABASE_PRODUCTION_DB_PASSWORD`
      do not exist (XCODE-CLOUD.md, "Current state"). `backend.yml` therefore
      has no production deploy job — wiring one up is a copy of
      `deploy-staging` with the ref check and secret names swapped, and the
      smoke job must stay pointed at staging (it creates users and posts rows).
- [x] **Set `devices.notify_friend_activity` from the client.** Done in Phase D:
      `PushRegistrar` writes the `AppSettings` toggle into the row through
      `register_device()`, and `AppState.settings.didSet` pushes a change
      straight through rather than waiting for the next foreground.
- [ ] **Client: re-fetch the roster and resting flags on a `posts` realtime
      event.** `circle_members` and `excused_days` are deliberately not
      published (see Privacy invariants), so those two are pull, not push.
- [ ] **Add `backend/supabase/.temp/` to `.gitignore`.** The Supabase CLI
      writes the linked project ref there; on a public repo that should never
      be committed by accident.
- [ ] **Schedule `retention`.** Nothing calls it yet, which is the one thing
      standing between the sweep described above and the ~30-day promise in §4.
      Options: `pg_cron` + `pg_net` on the project (neither is available in the
      sandbox, so it must be configured against the real database), or an
      external scheduler POSTing with the service-role key. The lease makes
      over-calling safe. **Whichever you pick, it must present the raw
      `SUPABASE_SERVICE_ROLE_KEY` as the bearer** — `isServiceRoleToken()`
      compares it verbatim and no longer trusts a decoded `role` claim, because
      that claim is what unlocks the destructive `days` knob. Do not reach for
      `--no-verify-jwt` while wiring this up.
- [ ] **Sweep orphaned `auth.users` rows.** `delete_account()` purges every
      row a user owns but cannot delete their `auth.users` row (that needs
      `service_role`); the app signs out immediately after. An admin sweep
      still has to remove the shells — including the throwaway CI users, and
      the circles they created, which linger on staging.
- [ ] **APNs secrets on the real project** (`supabase secrets set APNS_*`).
      Until then every push path logs and skips, by design.
- [ ] **Triage tooling for `reports`.** The client half shipped in Phase D
      (the control on a buddy photo, the local hide, the retry queue); what is
      still missing is somewhere for a human to actually READ the table —
      triage today means a service-role query by hand. App Store guideline 1.2
      needs a reader before public release.
- [ ] **Cross-timezone circles.** Accepted soft spot today. If circles stop
      being same-city, `day_key` has to grow a timezone story.
